# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Git status/commit modal overlay support.
    module GitPrompt
      def git_commit_message(status_lines)
        start
        @mutex.synchronize do
          prepare_modal_input_locked("Git>", clear_attachments: true)
          @git_state = git_state_for(status_lines)
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
              result = handle_git_key(key)
              render_prompt_locked unless result.is_a?(String) || result == SELECT_CANCEL || git_action?(result)
            end
          end

          if git_action?(result)
            action_result = block_given? ? yield(result) : status_lines
            refreshed_status = git_action_status_lines(action_result)
            open_git_diff_viewer(action_result[:diff]) if action_result.is_a?(Hash) && action_result[:diff]
            @mutex.synchronize do
              selected_index = @git_state ? @git_state[:selected_index].to_i : 0
              @git_state = git_state_for(refreshed_status, selected_index: selected_index)
              @prompt_label = "Git>"
              render_prompt_locked
            end
          elsif result.is_a?(String) || result == SELECT_CANCEL
            finish_git_prompt
            return result == SELECT_CANCEL ? nil : result
          end

          sleep 0.02 if key.nil?
        end
      end

      def open_modal_diff_viewer(path, content)
        @mutex.synchronize do
          open_diff_viewer(path.to_s, content.to_s)
          render_prompt_locked
        end
        read_editor_until_closed
      end

      private

      def handle_git_key(key)
        return git_submit_message if key.nil?
        return if handle_git_bracketed_paste_key(key)
        return if git_composing? && handle_shift_enter_key(key)

        csi_result = handle_git_csi_u_key(key)
        return csi_result unless csi_result == false

        return true if handle_bundled_key(key) { |token| handle_git_key(token) }

        case key
        when "\n", "\r"
          return git_submit_message if git_composing?
          return git_open_selected_file_diff
        when "\t"
          return git_composing? ? git_return_to_overlay : git_begin_message
        when "\b", "\x7F"
          return delete_before_cursor if git_composing?
        when "\e"
          return SELECT_CANCEL
        end

        key_name = key_name_for(key)
        named_result = handle_git_named_key(key_name) if key_name
        return named_result unless named_result == false || named_result.nil?

        binding_result = handle_composer_key_binding(key) if git_composing?
        return binding_result unless binding_result == false || binding_result.nil?

        return git_move_selection(1) if key == "j" && !git_composing?
        return git_move_selection(-1) if key == "k" && !git_composing?
        return git_toggle_selected_file if key == "s" && !git_composing?

        insert_key(key) if git_composing?
      end

      def handle_git_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        case code
        when 9
          git_composing? ? git_return_to_overlay : git_begin_message
        when 13
          git_composing? ? git_submit_message : git_open_selected_file_diff
        when 27
          SELECT_CANCEL
        when 8, 127
          git_composing? && alt_modifier?(modifier) ? delete_word_before_cursor : delete_before_cursor if git_composing?
          nil
        when 4
          delete_at_cursor if git_composing?
          nil
        else
          unless git_composing?
            return git_move_selection(1) if code == "j".ord
            return git_move_selection(-1) if code == "k".ord
            return git_toggle_selected_file if code == "s".ord && (sequence[:modifiers].to_s.empty? || sequence[:modifiers].to_s == "1")
          end
          return false unless git_composing?

          modified_result = handle_modified_csi_u_key(code, modifier)
          return modified_result unless modified_result == false

          insert_csi_u_text(sequence)
        end
      end

      def handle_git_bracketed_paste_key(key)
        handle_bracketed_paste(key) do |content|
          insert_string(content) if git_composing?
        end
      end

      def handle_git_named_key(key_name)
        case key_name
        when :return, :enter
          git_composing? ? git_submit_message : git_open_selected_file_diff
        when :backspace
          delete_before_cursor if git_composing?
        when :delete
          delete_at_cursor if git_composing?
        when :left
          move_cursor_left if git_composing?
        when :right
          move_cursor_right if git_composing?
        when :up
          git_composing? ? false : git_move_selection(-1)
        when :down
          git_composing? ? false : git_move_selection(1)
        when :home
          move_to_start_of_line if git_composing?
        when :end
          move_to_end_of_line if git_composing?
        else
          false
        end
      end

      def git_state_for(status_lines, selected_index: 0)
        lines = Array(status_lines).map(&:to_s)
        selected_index = [[selected_index.to_i, 0].max, [lines.length - 1, 0].max].min
        { status_lines: lines, composing: false, selected_index: selected_index, message_draft: "", message_cursor: 0 }
      end

      def git_action?(result)
        result.is_a?(Hash) && result[:action]
      end

      def git_move_selection(delta)
        return false unless @git_state

        count = @git_state[:status_lines].length
        return true if count.zero?

        @git_state[:selected_index] = [[@git_state[:selected_index].to_i + delta, 0].max, count - 1].min
        true
      end

      def git_toggle_selected_file
        return true unless @git_state
        return true if @git_state[:status_lines].empty?

        { action: :toggle_stage, index: @git_state[:selected_index].to_i }
      end

      def git_open_selected_file_diff
        return true unless @git_state
        return true if @git_state[:status_lines].empty?

        { action: :open_diff, index: @git_state[:selected_index].to_i }
      end

      def git_action_status_lines(action_result)
        return action_result[:status_lines] if action_result.is_a?(Hash) && action_result.key?(:status_lines)

        action_result
      end

      def open_git_diff_viewer(diff)
        return unless diff.respond_to?(:[])

        open_modal_diff_viewer(diff[:path], diff[:content])
      end

      def read_editor_until_closed
        while editor_active?
          key = read_key(nonblock: true)
          @mutex.synchronize do
            if key.nil?
              resized = handle_resize_locked
              footer_refreshed = tick_footer_locked
              render_prompt_locked if resized || footer_refreshed
            else
              handle_editor_key(key)
              render_prompt_locked if editor_active?
            end
          end
          sleep 0.02 if key.nil?
        end
      end

      def git_begin_message
        return true if git_composing?

        @git_state[:composing] = true if @git_state
        @prompt_label = "Commit>"
        self.composer_input = @git_state.fetch(:message_draft, "")
        self.composer_cursor = [[@git_state.fetch(:message_cursor, composer_input.length).to_i, 0].max, composer_input.length].min
        true
      end

      def git_return_to_overlay
        return true unless git_composing?

        @git_state[:message_draft] = composer_input.dup
        @git_state[:message_cursor] = composer_cursor
        @git_state[:composing] = false
        @prompt_label = "Git>"
        self.composer_input = ""
        self.composer_cursor = 0
        true
      end

      def git_submit_message
        return false unless git_composing?

        value = composer_input.dup
        add_history(composer_input)
        value
      end

      def git_composing?
        @git_state && @git_state[:composing]
      end

      def finish_git_prompt
        @mutex.synchronize do
          @git_state = nil
          self.composer_input = ""
          self.composer_cursor = 0
          @asking = true
          render_prompt_locked
          flush_output_locked
        end
      end

      def git_overlay_rows(width, height: screen_height)
        return [] unless @git_state

        help = git_composing? ? "Type commit message · Enter commit · Tab overlay · Esc cancel" : "↑/↓/j/k select · Enter diff · s stage/unstage · Tab message · Esc cancel"
        lines = [overlay_text_line(help, :muted), overlay_blank_line]
        status_lines = @git_state[:status_lines]
        status_lines = ["No uncommitted changes."] if status_lines.empty?
        max_status_rows = [max_overlay_list_rows(height), 1].max
        selected_index = @git_state[:selected_index].to_i
        start_index = centered_list_window_start(selected_index, status_lines.length, max_status_rows)
        visible_status_lines = status_lines[start_index, max_status_rows] || []
        lines << overlay_text_line("… #{start_index} above", :muted) if start_index.positive?
        visible_status_lines.each_with_index do |line, offset|
          index = start_index + offset
          marker = index == selected_index ? "› " : "  "
          lines << overlay_text_line("#{marker}#{line}")
        end
        hidden_below = status_lines.length - start_index - visible_status_lines.length
        lines << overlay_text_line("… #{hidden_below} more", :muted) if hidden_below.positive?
        overlay_card_rows("Git", lines, width)
      end
    end
  end
end
