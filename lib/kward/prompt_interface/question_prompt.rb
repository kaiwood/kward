# Namespace for the Kward CLI agent runtime.
module Kward
  # Structured question overlay used by ask_user_question.
  class PromptInterface
    # Structured question overlay used by the ask-user-question tool.
    module QuestionPrompt
      private

      def ask_single_user_question(question, index, total)
        @mutex.synchronize do
          prepare_modal_input_locked("Answer>")
          @question_state = {
            question: question[:question] || question["question"],
            header: question[:header] || question["header"],
            options: question[:options] || question["options"],
            selection_index: 0,
            index: index,
            total: total
          }
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
              result = drain_pending_question_keys_locked(result)
              render_prompt_locked unless result.is_a?(Hash) || result == SELECT_CANCEL
            end
          end

          return result if result.is_a?(Hash) || result == SELECT_CANCEL

          sleep 0.02 if key.nil?
        end
      end

      def drain_pending_question_keys_locked(result)
        until result.is_a?(Hash) || result == SELECT_CANCEL || @pending_keys.empty?
          result = handle_question_key(@pending_keys.shift)
        end
        result
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
          @question_prompt_active = false
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
        return if handle_question_shift_enter_key(key)

        csi_result = handle_question_csi_u_key(key)
        return csi_result unless csi_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_question_key(token)
          end
        end

        binding_result = handle_question_composer_key_binding(key)
        return binding_result unless binding_result == false

        case key_name_for(key)
        when :return, :enter
          current_question_answer
        when :backspace
          question_delete_before_cursor
        when :delete
          question_delete_at_cursor
        when :left
          move_cursor_left
        when :right
          move_cursor_right
        when :home
          move_to_start_of_line
        when :end
          move_to_end_of_line
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
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        case code
        when 13
          if modifier == 2
            question_insert_string("\n")
            nil
          else
            current_question_answer
          end
        when 27
          SELECT_CANCEL
        when 8, 127
          alt_modifier?(modifier) ? question_delete_word_before_cursor : question_delete_before_cursor
          nil
        else
          modified_result = handle_question_modified_csi_u_key(code, modifier)
          return modified_result unless modified_result == false
          return question_insert_csi_u_text(sequence) unless sequence[:text].to_s.empty?

          question_insert_csi_u_character(code, modifier)
        end
      end

      def handle_question_modified_csi_u_key(code, modifier)
        before = composer_input.dup
        result = handle_modified_csi_u_key(code, modifier)
        question_select_custom_choice if result != false && composer_input != before
        result
      end

      def question_insert_csi_u_text(sequence)
        text = csi_u_text(sequence)
        return false if text.empty?

        question_insert_string(text)
      end

      def question_insert_csi_u_character(code, modifier)
        return false if ctrl_modifier?(modifier) || alt_modifier?(modifier) || super_modifier?(modifier)
        return false unless code.between?(32, 126)

        question_insert_string(code.chr(Encoding::UTF_8))
      end

      def handle_question_escape_sequence
        pending_sequence = read_pending_escape_sequence
        return SELECT_CANCEL if pending_sequence.empty?

        full_sequence = "\e#{pending_sequence}"
        sequence = next_key_token(full_sequence)
        queue_pending_keys(full_sequence[sequence.length..]) if full_sequence.length > sequence.length
        return SELECT_CANCEL if sequence == "\e"

        binding_result = handle_question_composer_key_binding(sequence)
        return binding_result unless binding_result == false

        case key_name_for(sequence)
        when :up
          question_previous_choice
        when :down
          question_next_choice
        when :left
          move_cursor_left
        when :right
          move_cursor_right
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

      def handle_question_shift_enter_key(key)
        sequence = shift_enter_sequence_for(key)
        return false unless sequence

        question_insert_string("\n")
        queue_pending_keys(key[sequence.length..]) if key.length > sequence.length
        true
      end

      def handle_question_composer_key_binding(key)
        before = composer_input.dup
        result = handle_composer_key_binding(key)
        question_select_custom_choice if result != false && composer_input != before
        result
      end

      def question_insert_string(string)
        return if string.empty?

        insert_string(string)
        question_select_custom_choice
      end

      def question_delete_before_cursor
        before = composer_input.dup
        delete_before_cursor
        question_select_custom_choice if composer_input != before && !composer_input.empty?
      end

      def question_delete_at_cursor
        before = composer_input.dup
        delete_at_cursor
        question_select_custom_choice if composer_input != before && !composer_input.empty?
      end

      def question_delete_word_before_cursor
        before = composer_input.dup
        delete_word_before_cursor
        question_select_custom_choice if composer_input != before && !composer_input.empty?
      end

      def question_select_custom_choice
        @question_state[:selection_index] = question_choices.length - 1 if @question_state
      end

      def question_composer_layout(width, height = screen_height)
        content_width = [width - 4, 1].max
        overlay_rows = active_overlay_rows(width, height: height)
        return question_custom_composer_layout(width, height, overlay_rows, content_width) if selected_question_choice&.fetch(:custom, false)

        rows = overlay_rows + [top_border(width), box_content_row("", content_width)]
        rows.concat(question_bottom_border_rows(width))
        [rows, overlay_rows.length + 1, 2]
      end

      def question_custom_composer_layout(width, height, overlay_rows, content_width)
        input_layout_rows, input_cursor_row, input_cursor_col = input_layout(content_width)
        max_input_rows = max_visible_input_rows(0, overlay_rows.length, 0, height: height)
        visible_start = [[input_cursor_row - max_input_rows + 1, 0].max, [input_layout_rows.length - max_input_rows, 0].max].min
        visible_rows = input_layout_rows[visible_start, max_input_rows] || [""]
        rows = overlay_rows + [top_border(width)]
        rows.concat(visible_rows.map { |row| box_content_row(row, content_width) })
        rows.concat(question_bottom_border_rows(width))
        cursor_row = overlay_rows.length + 1 + input_cursor_row - visible_start
        cursor_col = 2 + [input_cursor_col, content_width - 1].min
        [rows, cursor_row, cursor_col]
      end

      def question_bottom_border_rows(width)
        @tabs.empty? ? [bottom_border(width)] : tab_border_rows(width)
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

      def choice_text(choice, selected: false)
        if choice[:custom]
          selected ? "Type a custom answer below." : "Type something."
        else
          description = choice[:description].empty? ? "" : " — #{choice[:description]}"
          "#{choice[:label]}#{description}"
        end
      end

    end
  end
end
