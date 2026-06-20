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

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_select_key(token)
          end
        end

        return handle_select_confirmation_key(key) if select_confirmation_active?

        csi_result = handle_select_csi_u_key(key)
        return csi_result unless csi_result == false

        return handle_select_input_key(key) if select_input_active?

        binding_result = handle_select_search_key_binding(key)
        return binding_result unless binding_result == false

        key_name = @reader.console.keys[key]
        case key_name
        when :return, :enter
          select_current_choice
        when :backspace
          select_delete_before_cursor if select_search_active?
        when :delete
          select_delete_at_cursor if select_search_active?
        when :left
          select_move_cursor_left if select_search_active?
        when :right
          select_move_cursor_right if select_search_active?
        when :home
          self.composer_cursor = 0 if select_search_active?
        when :end
          self.composer_cursor = composer_input.length if select_search_active?
        when :up
          select_previous_choice
        when :down
          select_next_choice
        else
          case key
          when "\n", "\r"
            select_current_choice
          when "\b", "\x7F"
            select_delete_before_cursor if select_search_active?
          when "\e"
            handle_select_escape_sequence
          else
            select_typed_key(key)
          end
        end
      end

      def handle_select_csi_u_key(key)
        match = key.to_s.match(/\A\e\[(\d+)(?:;([\d:]+))?u/)
        return false unless match

        sequence = match[0]
        code = match[1].to_i
        modifiers = match[2].to_s
        modifier = (modifiers.empty? ? "1" : modifiers).split(":", 2).first.to_i
        queue_pending_keys(key[sequence.length..]) if key.length > sequence.length

        case code
        when 13
          select_input_active? ? select_input_action_result : select_current_choice
        when 27
          if select_input_active?
            clear_select_input
          elsif select_search_active?
            select_cancel_search
          else
            SELECT_CANCEL
          end
        when 8, 127
          if select_editing_active?
            alt_modifier?(modifier) ? select_delete_word_before_cursor : select_delete_before_cursor
          end
          nil
        when 4
          select_delete_at_cursor if select_editing_active?
          nil
        else
          modified_result = handle_select_modified_csi_u_key(code, modifier)
          return modified_result unless modified_result == false

          handle_select_printable_csi_u_key(code, modifiers)
        end
      end

      def handle_select_modified_csi_u_key(code, modifier)
        return false unless select_editing_active?
        return false unless ctrl_modifier?(modifier) || alt_modifier?(modifier)

        normalized_code = code.to_i.chr.downcase.ord rescue code
        if ctrl_modifier?(modifier)
          handle_select_ctrl_key(normalized_code)
        elsif alt_modifier?(modifier)
          handle_select_alt_key(normalized_code)
        else
          false
        end
      end

      def handle_select_printable_csi_u_key(code, modifiers)
        return false unless modifiers.empty? || modifiers == "1"
        return false unless code.between?(32, 126)

        key = code.chr(Encoding::UTF_8)
        select_typed_key(key)
      end

      def handle_select_escape_sequence
        sequence = read_pending_escape_sequence
        return clear_select_input if sequence.empty? && select_input_active?
        return select_cancel_search if sequence.empty? && select_search_active?
        return SELECT_CANCEL if sequence.empty? || sequence.start_with?("\e")

        key_name = @reader.console.keys["\e#{sequence}"]
        case key_name
        when :up
          select_previous_choice
        when :down
          select_next_choice
        when :left
          select_move_cursor_left if select_editing_active?
        when :right
          select_move_cursor_right if select_editing_active?
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
        select_insert_string(normalize_paste(content || "")) if select_editing_active?
        queue_pending_keys(remaining) if remaining && !remaining.empty?
        true
      end

      def select_current_choice
        selected_selection_choice || custom_selection_choice || SELECT_CANCEL
      end

      def handle_select_confirmation_key(key)
        if key.to_s.start_with?("\e")
          clear_select_confirmation
          return true
        end

        key == @select_state[:confirm_key] ? select_action_key(key) : true
      end

      def handle_select_input_key(key)
        key_name = @reader.console.keys[key]
        case key_name
        when :return, :enter
          select_input_action_result
        when :backspace
          select_delete_before_cursor
        when :delete
          select_delete_at_cursor
        when :left
          select_move_cursor_left
        when :right
          select_move_cursor_right
        when :home
          self.composer_cursor = 0
        when :end
          self.composer_cursor = composer_input.length
        else
          case key
          when "\n", "\r"
            select_input_action_result
          when "\b", "\x7F"
            select_delete_before_cursor
          when "\e"
            clear_select_input
            true
          else
            handle_select_search_key_binding(key) || select_insert_key(key)
          end
        end
      end

      def select_action_key(key)
        return nil unless key.is_a?(String) && key.length == 1

        action_keys = @select_state ? @select_state[:action_keys].to_h : {}
        action = action_keys[key]
        choice = selected_selection_choice
        return nil unless action && choice

        if select_confirmation_active?
          return nil unless key == @select_state[:confirm_key]

          clear_select_confirmation
          return action.merge(choice: choice).reject { |name, _value| name == :confirm || name == :confirm_title }
        end

        if action[:confirm]
          @select_state[:confirm_key] = key
          @select_state[:confirm_text] = action[:confirm].to_s
          @select_state[:confirm_title] = action[:confirm_title].to_s
          return true
        end

        if action[:input_prompt]
          @select_state[:input_action] = action
          @select_state[:input_choice] = choice
          @select_state[:input_prompt_label] = @prompt_label
          @prompt_label = action[:input_prompt].to_s
          self.composer_input = ""
          self.composer_cursor = 0
          return true
        end

        action.merge(choice: choice)
      end

      def select_confirmation_active?
        @select_state && !@select_state[:confirm_key].to_s.empty?
      end

      def select_input_active?
        @select_state && @select_state[:input_action]
      end

      def select_input_action_result
        return unless @select_state

        action = @select_state[:input_action].dup
        choice = @select_state[:input_choice]
        input = composer_input.strip
        clear_select_input
        action.merge(choice: choice, input: input).reject { |name, _value| name == :input_prompt }
      end

      def clear_select_input
        return unless @select_state

        @prompt_label = @select_state[:input_prompt_label].to_s unless @select_state[:input_prompt_label].to_s.empty?
        @select_state.delete(:input_action)
        @select_state.delete(:input_choice)
        @select_state.delete(:input_prompt_label)
        self.composer_input = ""
        self.composer_cursor = 0
      end

      def clear_select_confirmation
        return unless @select_state

        @select_state.delete(:confirm_key)
        @select_state.delete(:confirm_text)
        @select_state.delete(:confirm_title)
      end

      def select_action_result?(result)
        result.is_a?(Hash) && result.key?(:action) && result.key?(:choice)
      end

      def select_action_handler(result, action_handlers)
        action_handlers.to_h[result[:action]] || action_handlers.to_h[result[:action].to_s]
      end

      def run_select_action(result, handler)
        begin_select_action(result[:activity])
        minimum_busy_until = result[:activity] ? monotonic_now + SELECT_ACTION_MINIMUM_BUSY_SECONDS : nil
        action_result = nil
        action_error = nil
        worker = Thread.new do
          action_result = if result.key?(:input) && handler.arity != 1
                            handler.call(result[:choice], result[:input])
                          else
                            handler.call(result[:choice])
                          end
        rescue StandardError => e
          action_error = e
        end

        while worker.alive? || (minimum_busy_until && monotonic_now < minimum_busy_until)
          tick_select_action_locked
          sleep 0.02
        end
        worker.join
        raise action_error if action_error

        apply_select_action_result(action_result)
      ensure
        finish_select_action
      end

      def apply_select_action_result(result)
        return SELECT_CONTINUE if result == SELECT_CONTINUE
        return result unless select_continue_result?(result)

        @mutex.synchronize do
          if @select_state
            @select_state[:choices] = Array(result[:choices]).map(&:to_s) if result.key?(:choices)
            @select_state[:selection_index] = result[:selection_index].to_i if result.key?(:selection_index)
          end
          render_prompt_locked
          @output_io.flush
        end
        SELECT_CONTINUE
      end

      def select_continue_result?(result)
        result.is_a?(Hash) && result[:select_continue]
      end

      def begin_select_action(activity)
        return if activity.to_s.empty?

        @mutex.synchronize do
          @busy = true
          @busy_activity = normalize_busy_activity(activity)
          @asking = true
          reset_spinner_locked
          render_prompt_locked
          @output_io.flush
        end
      end

      def finish_select_action
        @mutex.synchronize do
          @busy = false
          @busy_activity = "streaming"
          @select_state&.delete(:busy_activity)
          render_prompt_locked if @asking
          @output_io.flush
        end
      end

      def tick_select_action_locked
        @mutex.synchronize do
          resized = handle_resize_locked
          spun = tick_spinner_locked
          footer_refreshed = tick_footer_locked
          render_prompt_locked if resized || spun || footer_refreshed
          @output_io.flush if resized || spun || footer_refreshed
        end
      end

      def normalized_select_action_keys(action_keys)
        action_keys.to_h.each_with_object({}) do |(key, action), normalized|
          next unless key.to_s.length == 1

          normalized_action = normalized_select_action(action)
          normalized[key.to_s] = normalized_action if normalized_action
        end
      end

      def normalized_select_action(action)
        if action.is_a?(Hash)
          name = action[:action] || action["action"]
          activity = action[:activity] || action["activity"]
          confirm = action[:confirm] || action["confirm"]
          confirm_title = action[:confirm_title] || action["confirm_title"]
          input_prompt = action[:input_prompt] || action["input_prompt"]
          defer_finish_render = action[:defer_finish_render] || action["defer_finish_render"]
        else
          name = action
        end
        return nil if name.to_s.empty?

        { action: name.to_sym, activity: activity.to_s, confirm: confirm.to_s, confirm_title: confirm_title.to_s, input_prompt: input_prompt.to_s, defer_finish_render: defer_finish_render }.delete_if { |_key, value| value.to_s.empty? }
      end

      def custom_selection_choice
        return nil unless @select_state && @select_state[:custom] && select_search_active?

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

      def handle_select_search_key_binding(key)
        return false unless select_editing_active?

        case key
        when "\x01"
          select_move_to_start_of_line
        when "\x02"
          select_move_cursor_left
        when "\x04"
          select_delete_at_cursor
        when "\x05"
          select_move_to_end_of_line
        when "\x06"
          select_move_cursor_right
        when "\x08"
          select_delete_before_cursor
        when "\x0B"
          select_kill_line_after_cursor
        when "\x0C"
          redraw_screen_locked
        when "\x15"
          select_kill_line_before_cursor
        when "\x17"
          select_delete_word_before_cursor
        when "\x19"
          select_yank_kill_buffer
        when "\eb"
          select_move_to_previous_word
        when "\ed"
          select_delete_word_after_cursor
        when "\ef"
          select_move_to_next_word
        when "\e\b", "\e\x7F"
          select_delete_word_before_cursor
        else
          false
        end
      end

      def handle_select_ctrl_key(code)
        case code
        when 97
          select_move_to_start_of_line
        when 98
          select_move_cursor_left
        when 100
          select_delete_at_cursor
        when 101
          select_move_to_end_of_line
        when 102
          select_move_cursor_right
        when 104
          select_delete_before_cursor
        when 107
          select_kill_line_after_cursor
        when 108
          redraw_screen_locked
        when 117
          select_kill_line_before_cursor
        when 119
          select_delete_word_before_cursor
        when 121
          select_yank_kill_buffer
        else
          false
        end
      end

      def handle_select_alt_key(code)
        case code
        when 98
          select_move_to_previous_word
        when 100
          select_delete_word_after_cursor
        when 102
          select_move_to_next_word
        else
          false
        end
      end

      def select_typed_key(key)
        return select_insert_key(key) if select_input_active?
        return select_begin_search if key == "/" && !select_search_active?
        return select_action_key(key) unless select_search_active?

        select_insert_key(key)
      end

      def select_begin_search
        return unless @select_state

        @select_state[:search_active] = true
        self.composer_input = ""
        self.composer_cursor = 0
        true
      end

      def select_cancel_search
        return unless @select_state

        @select_state[:search_active] = false
        self.composer_input = ""
        self.composer_cursor = 0
        @select_state[:selection_index] = 0
        true
      end

      def select_search_active?
        @select_state && @select_state[:search_active]
      end

      def select_editing_active?
        select_search_active? || select_input_active?
      end

      def select_move_cursor_left
        @composer.move_cursor_left
      end

      def select_move_cursor_right
        @composer.move_cursor_right
      end

      def select_move_to_start_of_line
        @composer.move_to_start_of_line
      end

      def select_move_to_end_of_line
        @composer.move_to_end_of_line
      end

      def select_move_to_previous_word
        @composer.move_to_previous_word
      end

      def select_move_to_next_word
        @composer.move_to_next_word
      end

      def select_delete_word_before_cursor
        reset_select_filter if @composer.delete_word_before_cursor
      end

      def select_delete_word_after_cursor
        reset_select_filter if @composer.delete_word_after_cursor
      end

      def select_kill_line_before_cursor
        reset_select_filter if @composer.kill_line_before_cursor
      end

      def select_kill_line_after_cursor
        reset_select_filter if @composer.kill_line_after_cursor
      end

      def select_yank_kill_buffer
        before = composer_input
        @composer.yank_kill_buffer
        reset_select_filter unless composer_input == before
      end

      def select_insert_key(key)
        return unless key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)

        select_insert_string(key)
      end

      def select_insert_string(string)
        return if string.empty?

        @composer.insert_string(string)
        reset_select_filter
      end

      def select_delete_before_cursor
        reset_select_filter if @composer.delete_before_cursor
      end

      def select_delete_at_cursor
        reset_select_filter if @composer.delete_at_cursor
      end

      def reset_select_filter
        @select_state[:selection_index] = 0 if @select_state && !select_input_active?
      end

      def selection_matches
        choices = @select_state ? @select_state[:choices] : []
        filter = select_search_active? ? composer_input.downcase.strip : ""
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

      def finish_select_prompt(render: true)
        @mutex.synchronize do
          @select_state = nil
          self.composer_input = ""
          self.composer_cursor = 0
          @asking = true
          render_prompt_locked if render
          @output_io.flush
        end
      end

      def select_deferred_finish_render?(result)
        result.is_a?(Hash) && result[:defer_finish_render]
      end

      def selection_overlay_rows(width, height: screen_height)
        return selection_confirmation_rows(width) if select_confirmation_active?

        matches = selection_matches
        lines = [overlay_text_line(selection_overlay_help_text, :muted), overlay_blank_line]
        if matches.empty?
          if @select_state && @select_state[:custom] && select_search_active? && !composer_input.strip.empty?
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

      def selection_overlay_help_text
        return "Renaming · Enter save · Esc cancel" if select_input_active?

        text = "↑/↓ select · Enter open"
        text = "#{text} · / search" unless select_search_active?
        action_keys = @select_state ? @select_state[:action_keys].to_h : {}
        action_keys.each do |key, action|
          text = "#{text} · #{key} #{action[:action]}"
        end
        "#{text} · Esc cancel"
      end

      def selection_overlay_title
        title = @select_state && @select_state[:title].to_s
        title && !title.empty? ? title : "Sessions"
      end

      def selection_confirmation_rows(width)
        title = @select_state[:confirm_title].to_s
        title = "Confirm" if title.empty?
        text = @select_state[:confirm_text].to_s
        text = "Press #{@select_state[:confirm_key]} again to confirm, Esc to cancel." if text.empty?
        lines = [overlay_text_line(text, :muted)]
        overlay_card_rows(title, lines, width)
      end

      def visible_selection_matches(matches, height: screen_height)
        max_rows = max_overlay_list_rows(height)
        start = centered_list_window_start(selection_index, matches.length, max_rows)
        { start: start, choices: matches[start, max_rows] || [] }
      end

    end
  end
end
