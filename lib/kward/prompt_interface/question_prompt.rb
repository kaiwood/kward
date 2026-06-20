# Namespace for the Kward CLI agent runtime.
module Kward
  # Structured question overlay used by ask_user_question.
  class PromptInterface
    # Structured question overlay used by the ask-user-question tool.
    module QuestionPrompt
      private

      def ask_single_user_question(question, index, total)
        @mutex.synchronize do
          @prompt_label = "Answer>"
          self.composer_input = ""
          self.composer_cursor = 0
          @pending_keys.clear
          @asking = true
          @busy = false
          @queued_count = 0
          @question_state = {
            question: question[:question] || question["question"],
            header: question[:header] || question["header"],
            options: question[:options] || question["options"],
            selection_index: 0,
            index: index,
            total: total
          }
          reset_history_navigation
          render_prompt_locked
        end

        loop do
          key = read_key(nonblock: true)
          result = nil
          @mutex.synchronize do
            if key.nil?
              resized = handle_resize_locked
              footer_refreshed = tick_footer_locked
              render_prompt_locked if resized || footer_refreshed
            else
              result = handle_question_key(key)
              render_prompt_locked unless result.is_a?(Hash) || result == SELECT_CANCEL
            end
          end

          return result if result.is_a?(Hash) || result == SELECT_CANCEL

          sleep 0.02 if key.nil?
        end
      end

      def begin_question_prompt_state
        {
          prompt_label: @prompt_label,
          input: composer_input,
          cursor: composer_cursor,
          asking: @asking,
          busy: @busy,
          queued_count: @queued_count,
          steered_count: @steered_count,
          pending_keys: @pending_keys.dup,
          select_state: @select_state
        }
      end

      def finish_question_prompt(saved_state)
        @mutex.synchronize do
          @question_state = nil
          @select_state = saved_state[:select_state]
          @prompt_label = saved_state[:prompt_label]
          self.composer_input = saved_state[:input]
          self.composer_cursor = saved_state[:cursor]
          @asking = saved_state[:asking]
          @busy = saved_state[:busy]
          @queued_count = saved_state[:queued_count]
          @steered_count = saved_state[:steered_count]
          @pending_keys = saved_state[:pending_keys]
          render_prompt_locked if @started && @asking
          @output_io.flush
        end
      end

      def handle_question_key(key)
        return if handle_question_bracketed_paste_key(key)

        csi_result = handle_question_csi_u_key(key)
        return csi_result unless csi_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_question_key(token)
          end
        end

        key_name = @reader.console.keys[key]
        case key_name
        when :return, :enter
          current_question_answer
        when :backspace
          question_delete_before_cursor
        when :delete
          question_delete_at_cursor
        when :left
          @composer.move_cursor_left
        when :right
          @composer.move_cursor_right
        when :home
          @composer.move_to_start_of_line
        when :end
          @composer.move_to_end_of_line
        when :up
          question_previous_choice
        when :down
          question_next_choice
        else
          case key
          when "\n", "\r"
            current_question_answer
          when "\b", "\x7F"
            question_delete_before_cursor
          when "\e"
            handle_question_escape_sequence
          else
            question_insert_key(key)
          end
        end
      end

      def handle_question_csi_u_key(key)
        match = key.to_s.match(/\A\e\[(\d+)(?:;([\d:]+))?u/)
        return false unless match

        sequence = match[0]
        code = match[1].to_i
        queue_pending_keys(key[sequence.length..]) if key.length > sequence.length

        case code
        when 13
          current_question_answer
        when 27
          SELECT_CANCEL
        when 8, 127
          question_delete_before_cursor
          nil
        else
          false
        end
      end

      def handle_question_escape_sequence
        sequence = read_pending_escape_sequence
        return SELECT_CANCEL if sequence.empty?

        key_name = @reader.console.keys["\e#{sequence}"]
        case key_name
        when :up
          question_previous_choice
        when :down
          question_next_choice
        when :left
          @composer.move_cursor_left
        when :right
          @composer.move_cursor_right
        end
        true
      end

      def handle_question_bracketed_paste_key(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        question_insert_string(normalize_paste(paste[:content]))
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

      def current_question_answer
        choice = selected_question_choice
        return nil unless choice

        if choice[:custom]
          answer = composer_input.strip
          return nil if answer.empty?

          { question: current_question_text, answer: answer, custom: true }
        else
          { question: current_question_text, answer: choice[:label], custom: false }
        end
      end

      def selected_question_choice
        choices = question_choices
        return nil if choices.empty?

        choices[question_selection_index]
      end

      def question_choices
        options = Array(@question_state ? @question_state[:options] : []).map do |option|
          { label: (option[:label] || option["label"]).to_s, description: (option[:description] || option["description"]).to_s }
        end
        choices = options + [{ label: "Type something.", description: composer_input.strip, custom: true }]
        clamp_question_selection_index(choices.length)
        choices
      end

      def current_question_text
        (@question_state && @question_state[:question]).to_s
      end

      def question_selection_index
        @question_state ? @question_state[:selection_index].to_i : 0
      end

      def clamp_question_selection_index(count)
        return unless @question_state

        @question_state[:selection_index] = 0 if count <= 0
        @question_state[:selection_index] = count - 1 if count.positive? && question_selection_index >= count
      end

      def question_previous_choice
        choices = question_choices
        return if choices.empty?

        @question_state[:selection_index] = (question_selection_index - 1) % choices.length
      end

      def question_next_choice
        choices = question_choices
        return if choices.empty?

        @question_state[:selection_index] = (question_selection_index + 1) % choices.length
      end

      def question_insert_key(key)
        return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

        question_insert_string(key)
      end

      def question_insert_string(string)
        return if string.empty?

        @composer.insert_string(string)
        @question_state[:selection_index] = question_choices.length - 1 if @question_state
      end

      def question_delete_before_cursor
        return unless @composer.delete_before_cursor

        @question_state[:selection_index] = question_choices.length - 1 if @question_state && !composer_input.empty?
      end

      def question_delete_at_cursor
        return unless @composer.delete_at_cursor

        @question_state[:selection_index] = question_choices.length - 1 if @question_state && !composer_input.empty?
      end

      def question_composer_layout(width, height = screen_height)
        content_width = [width - 4, 1].max
        overlay_rows = active_overlay_rows(width, height: height)
        rows = overlay_rows + [top_border(width), box_content_row("", content_width), bottom_border(width)]
        return [rows, question_custom_cursor_row, question_custom_cursor_col(width)] if selected_question_choice&.fetch(:custom, false)

        [rows, overlay_rows.length + 1, 2]
      end

      def question_overlay_rows(width)
        title = "Question #{@question_state[:index]}/#{@question_state[:total]} · #{@question_state[:header]}"
        lines = [
          overlay_text_line(@question_state[:question].to_s, :bold),
          overlay_text_line("↑/↓ select · Enter choose · Esc cancel", :muted),
          overlay_blank_line
        ]
        question_choices.each_with_index do |choice, index|
          selected = index == question_selection_index
          lines << overlay_choice_line(choice_text(choice, selected: selected), selected: selected)
        end
        overlay_card_rows(title, lines, width)
      end

      def question_custom_cursor_row
        4 + question_choices.index { |choice| choice[:custom] }.to_i
      end

      def question_custom_cursor_col(width)
        card_width = overlay_card_width(width)
        left_padding = overlay_left_padding(width, card_width)
        custom_prefix = selected_question_choice&.fetch(:custom, false) || !composer_input.empty? ? "Type something: " : "Type something."
        visible_before_cursor = display_question_input(composer_input[0...composer_cursor])
        [[left_padding + 2 + 2 + custom_prefix.length + visible_before_cursor.length, width - 1].min, 0].max
      end

      def choice_text(choice, selected: false)
        if choice[:custom]
          if selected || !composer_input.empty?
            "Type something: #{display_question_input(composer_input)}"
          else
            "Type something."
          end
        else
          description = choice[:description].empty? ? "" : " — #{choice[:description]}"
          "#{choice[:label]}#{description}"
        end
      end

      def display_question_input(value)
        value.to_s.gsub(/\s+/, " ")
      end

    end
  end
end
