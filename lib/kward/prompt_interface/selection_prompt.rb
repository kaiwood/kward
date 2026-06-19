# Namespace for the Kward CLI agent runtime.
module Kward
  # Selection overlay implementation for list-style prompts.
  class PromptInterface
    # Selection-list overlay support for prompt choices.
    module SelectionPrompt
      private

      def handle_select_key(key)
        return select_current_choice if key.nil?
        return if handle_select_bracketed_paste_key(key)

        csi_result = handle_select_csi_u_key(key)
        return csi_result unless csi_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_select_key(token)
          end
        end

        key_name = @reader.console.keys[key]
        case key_name
        when :return, :enter
          select_current_choice
        when :backspace
          select_delete_before_cursor
        when :delete
          select_delete_at_cursor
        when :left
          self.composer_cursor -= 1 if composer_cursor.positive?
        when :right
          self.composer_cursor += 1 if composer_cursor < composer_input.length
        when :home
          self.composer_cursor = 0
        when :end
          self.composer_cursor = composer_input.length
        when :up
          select_previous_choice
        when :down
          select_next_choice
        else
          case key
          when "\n", "\r"
            select_current_choice
          when "\b", "\x7F"
            select_delete_before_cursor
          when "\e"
            handle_select_escape_sequence
          else
            select_insert_key(key)
          end
        end
      end

      def handle_select_csi_u_key(key)
        match = key.to_s.match(/\A\e\[(\d+)(?:;([\d:]+))?u/)
        return false unless match

        sequence = match[0]
        code = match[1].to_i
        queue_pending_keys(key[sequence.length..]) if key.length > sequence.length

        case code
        when 13
          select_current_choice
        when 27
          SELECT_CANCEL
        when 8, 127
          select_delete_before_cursor
          nil
        else
          false
        end
      end

      def handle_select_escape_sequence
        sequence = read_pending_escape_sequence
        return SELECT_CANCEL if sequence.empty? || sequence.start_with?("\e")

        key_name = @reader.console.keys["\e#{sequence}"]
        case key_name
        when :up
          select_previous_choice
        when :down
          select_next_choice
        when :left
          self.composer_cursor -= 1 if composer_cursor.positive?
        when :right
          self.composer_cursor += 1 if composer_cursor < composer_input.length
        end
        true
      end

      def handle_select_bracketed_paste_key(key)
        text = key.to_s
        return false unless text.start_with?(BRACKETED_PASTE_START)

        pasted = text[BRACKETED_PASTE_START.length..] || ""
        until pasted.include?(BRACKETED_PASTE_END)
          chunk = @reader.read_keypress(echo: false, raw: true)
          break if chunk.nil?

          pasted << chunk.to_s
        end

        content, remaining = pasted.split(BRACKETED_PASTE_END, 2)
        select_insert_string(normalize_paste(content || ""))
        queue_pending_keys(remaining) if remaining && !remaining.empty?
        true
      end

      def select_current_choice
        selected_selection_choice || custom_selection_choice || SELECT_CANCEL
      end

      def custom_selection_choice
        return nil unless @select_state && @select_state[:custom]

        value = composer_input.strip
        value.empty? ? nil : value
      end

      def selected_selection_choice
        matches = selection_matches
        return nil if matches.empty?

        matches[selection_index]
      end

      def select_previous_choice
        matches = selection_matches
        return if matches.empty?

        @select_state[:selection_index] = previous_list_selection_index(selection_index, matches.length)
      end

      def select_next_choice
        matches = selection_matches
        return if matches.empty?

        @select_state[:selection_index] = next_list_selection_index(selection_index, matches.length)
      end

      def select_insert_key(key)
        return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

        select_insert_string(key)
      end

      def select_insert_string(string)
        return if string.empty?

        self.composer_input = composer_input[0...composer_cursor] + string + composer_input[composer_cursor..]
        self.composer_cursor += string.length
        @select_state[:selection_index] = 0 if @select_state
      end

      def select_delete_before_cursor
        return unless composer_cursor.positive?

        self.composer_input = composer_input[0...(composer_cursor - 1)] + composer_input[composer_cursor..]
        self.composer_cursor -= 1
        @select_state[:selection_index] = 0 if @select_state
      end

      def select_delete_at_cursor
        return unless composer_cursor < composer_input.length

        self.composer_input = composer_input[0...composer_cursor] + composer_input[(composer_cursor + 1)..]
        @select_state[:selection_index] = 0 if @select_state
      end

      def selection_matches
        choices = @select_state ? @select_state[:choices] : []
        filter = composer_input.downcase.strip
        matches = filter.empty? ? choices : choices.select { |choice| choice.downcase.include?(filter) }
        clamp_selection_index(matches.length)
        matches
      end

      def selection_index
        @select_state ? @select_state[:selection_index].to_i : 0
      end

      def clamp_selection_index(count)
        return unless @select_state

        @select_state[:selection_index] = 0 if count <= 0
        @select_state[:selection_index] = count - 1 if count.positive? && selection_index >= count
      end

      def finish_select_prompt
        @mutex.synchronize do
          @select_state = nil
          self.composer_input = ""
          self.composer_cursor = 0
          @asking = true
          render_prompt_locked
          @output_io.flush
        end
      end

      def selection_overlay_rows(width, height: screen_height)
        matches = selection_matches
        lines = [overlay_text_line("↑/↓ select · Enter open · Esc cancel", :muted), overlay_blank_line]
        if matches.empty?
          if @select_state && @select_state[:custom] && !composer_input.strip.empty?
            lines << overlay_choice_line("Use custom: #{composer_input.strip}", selected: true)
          else
            lines << overlay_text_line("No matches", :muted)
          end
          return overlay_card_rows(selection_overlay_title, lines, width)
        end

        visible = visible_selection_matches(matches, height: height)
        start_index = visible[:start]
        visible[:choices].each_with_index do |choice, offset|
          index = start_index + offset
          lines << overlay_choice_line(choice, selected: index == selection_index)
        end
        overlay_card_rows(selection_overlay_title, lines, width)
      end

      def selection_overlay_title
        title = @select_state && @select_state[:title].to_s
        title && !title.empty? ? title : "Sessions"
      end

      def visible_selection_matches(matches, height: screen_height)
        max_rows = max_overlay_list_rows(height)
        start = centered_list_window_start(selection_index, matches.length, max_rows)
        { start: start, choices: matches[start, max_rows] || [] }
      end

    end
  end
end
