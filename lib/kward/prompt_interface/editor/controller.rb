# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Built-in composer file editor behavior.
    module EditorController
      private

      def editor_active?
        !@editor_state.nil?
      end

      def open_selected_file_in_editor(fallback_to_typed_path: false)
        path = selected_file_open_path
        return open_editor(path) if path
        return false unless fallback_to_typed_path

        open_typed_file_path_in_editor
      end

      def open_typed_file_path_in_editor
        file_open = active_file_open
        return false unless file_open
        if file_open[:query].empty?
          @file_editor_open_status = "Type a file path after $"
          return false
        end

        open_editor(file_open[:query], allow_new: true)
      end

      def open_editor(path, allow_new: false)
        full_path = File.expand_path(path.to_s, Dir.pwd)
        root = File.expand_path(Dir.pwd)
        unless full_path == root || full_path.start_with?("#{root}/")
          @file_editor_open_status = "Cannot edit file outside workspace"
          return false
        end
        if File.exist?(full_path) && !File.file?(full_path)
          @file_editor_open_status = "Cannot edit non-file path: #{path}"
          return false
        end
        unless File.exist?(full_path)
          unless allow_new
            @file_editor_open_status = "Cannot edit missing file: #{path}"
            return false
          end
          parent = File.dirname(full_path)
          unless Dir.exist?(parent)
            @file_editor_open_status = "Cannot create file; parent directory is missing"
            return false
          end
        end

        @editor_state = EditorState.new(path: full_path, content: File.exist?(full_path) ? File.read(full_path) : "", new_file: !File.exist?(full_path), editor_mode: current_editor_mode)
        @prompt_label = "Edit>"
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @pending_keys.clear
        @file_overlay_dismissed_token = nil
        @file_open_dismissed_token = nil
        @asking = true
        true
      rescue StandardError => e
        @file_editor_open_status = "Cannot edit #{path}: #{e.message}"
        false
      end

      def current_editor_mode
        return normalize_editor_mode(@editor_mode_source.call) if @editor_mode_source.respond_to?(:call)

        @editor_mode
      rescue StandardError
        @editor_mode
      end

      def close_editor
        @editor_state = nil
        @prompt_label = "You>"
        self.composer_input = ""
        self.composer_cursor = 0
        @asking = true
      end

      def handle_editor_key(key)
        return if key.nil?
        return handle_vibe_key(key) if @editor_state&.vibe?
        return handle_emacs_key(key) if @editor_state&.emacs?
        return handle_modern_key(key) if @editor_state&.modern?
        return if handle_editor_bracketed_paste_key(key)

        csi_result = handle_editor_csi_u_key(key)
        return csi_result unless csi_result == false

        shift_result = handle_editor_shift_navigation_key(key)
        return shift_result unless shift_result == false

        binding_result = handle_editor_key_binding(key)
        return binding_result unless binding_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        if key.is_a?(String) && key.length > 1
          token = next_key_token(key)
          if token.length < key.length
            queue_pending_keys(key[token.length..])
            return handle_editor_key(token)
          end
        end

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          clear_editor_selection_before_edit
          editor_insert_newline
        when "\t"
          clear_editor_selection_before_edit
          @editor_state.insert("  ") unless editor_search_active?
        when "\b", "\x7F"
          editor_search_active? ? editor_search_delete_character : delete_editor_selection || editor_delete_before_cursor
        when "\x03"
          return editor_search_cancel if editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          return @editor_state.clear_selection if @editor_state.selection_active?
        when "\x11"
          quit_editor
        when "\x13"
          save_editor
        when "/"
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        else
          key_name = key_name_for(key)
          named_result = handle_editor_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          elsif printable_key?(key)
            clear_editor_selection_before_edit
            editor_insert_printable(key)
          end
        end
      end

      def handle_editor_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        binding_result = handle_editor_modified_csi_u_key(code, modifier)
        return binding_result unless binding_result == false

        case code
        when 13
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_confirm : editor_insert_newline
        when 27
          editor_search_active? ? editor_search_cancel : @editor_state.clear_selection
        when 8, 127
          editor_search_active? ? editor_search_delete_character : delete_editor_selection || editor_delete_before_cursor
          nil
        when 4
          delete_editor_selection || @editor_state.delete_at_cursor unless editor_search_active?
          nil
        else
          return false unless sequence[:modifiers].to_s.empty? || sequence[:modifiers].to_s == "1"
          return false unless code.between?(32, 126)

          char = code.chr(Encoding::UTF_8)
          clear_editor_selection_before_edit unless editor_search_active?
          editor_search_active? ? editor_search_append(char) : editor_insert_printable(char)
        end
      end

      def handle_editor_shift_navigation_key(key)
        return false if editor_search_active?

        case key
        when "\e[1;2D", "\e[2D"
          editor_extending_selection { @editor_state.move_left }
        when "\e[1;2C", "\e[2C"
          editor_extending_selection { @editor_state.move_right }
        when "\e[1;2A", "\e[2A"
          editor_extending_selection { @editor_state.move_up }
        when "\e[1;2B", "\e[2B"
          editor_extending_selection { @editor_state.move_down }
        else
          false
        end
      end

      def handle_editor_key_binding(key)
        case key
        when "\x01"
          @editor_state.move_line_start unless editor_search_active?
        when "\x02"
          @editor_state.move_left unless editor_search_active?
        when "\x04"
          @editor_state.delete_at_cursor unless editor_search_active?
        when "\x05"
          @editor_state.move_line_end unless editor_search_active?
        when "\x06"
          @editor_state.move_right unless editor_search_active?
        when "\x00"
          @editor_state.begin_selection unless editor_search_active?
        when "\x0B"
          @editor_state.kill_line_after_cursor unless editor_search_active?
        when "\x0E"
          @editor_state.move_down unless editor_search_active?
        when "\x10"
          @editor_state.move_up unless editor_search_active?
        when "\x15"
          @editor_state.kill_line_before_cursor unless editor_search_active?
        when "\x17"
          @editor_state.delete_word_before_cursor unless editor_search_active?
        when "\x19"
          editor_selection_active? ? copy_editor_selection : @editor_state.yank_kill_buffer unless editor_search_active?
        when "\e[D", "\eOD"
          @editor_state.move_left unless editor_search_active?
        when "\e[C", "\eOC"
          @editor_state.move_right unless editor_search_active?
        when "\e[H", "\eOH", "\e[1~", "\e[7~"
          @editor_state.move_line_start unless editor_search_active?
        when "\e[F", "\eOF", "\e[4~", "\e[8~"
          @editor_state.move_line_end unless editor_search_active?
        when "\e[3~"
          delete_editor_selection || @editor_state.delete_at_cursor unless editor_search_active?
        when "\eb", "\eB"
          @editor_state.move_to_previous_word unless editor_search_active?
        when "\ef", "\eF"
          @editor_state.move_to_next_word unless editor_search_active?
        when "\ed", "\eD"
          @editor_state.delete_word_after_cursor unless editor_search_active?
        when "\e\b", "\e\x7F"
          @editor_state.delete_word_before_cursor unless editor_search_active?
        else
          handle_editor_modified_ansi_key(key) || false
        end
      end

      def handle_editor_modified_csi_u_key(code, modifier)
        return false unless ctrl_modifier?(modifier) || alt_modifier?(modifier)

        normalized_code = code.to_i.chr.downcase.ord rescue code
        if ctrl_modifier?(modifier)
          case normalized_code
          when 32
            @editor_state.begin_selection unless editor_search_active?
          when 97
            @editor_state.move_line_start unless editor_search_active?
          when 98
            @editor_state.move_left unless editor_search_active?
          when 99
            editor_search_cancel if editor_search_active?
          when 100
            @editor_state.delete_at_cursor unless editor_search_active?
          when 101
            @editor_state.move_line_end unless editor_search_active?
          when 102
            @editor_state.move_right unless editor_search_active?
          when 107
            @editor_state.kill_line_after_cursor unless editor_search_active?
          when 110
            @editor_state.move_down unless editor_search_active?
          when 112
            @editor_state.move_up unless editor_search_active?
          when 113
            quit_editor
          when 115
            save_editor
          when 117
            @editor_state.kill_line_before_cursor unless editor_search_active?
          when 119
            @editor_state.delete_word_before_cursor unless editor_search_active?
          when 121
            editor_selection_active? ? copy_editor_selection : @editor_state.yank_kill_buffer unless editor_search_active?
          else
            false
          end
        elsif alt_modifier?(modifier)
          case normalized_code
          when 98
            @editor_state.move_to_previous_word unless editor_search_active?
          when 100
            @editor_state.delete_word_after_cursor unless editor_search_active?
          when 102
            @editor_state.move_to_next_word unless editor_search_active?
          else
            false
          end
        else
          false
        end
      end

      def handle_editor_modified_ansi_key(key)
        match = key.to_s.match(/\A\e\[(\d+);(\d+)([CDFH])\z/)
        if match
          modifier = match[2].to_i
          final = match[3]
          return false unless alt_modifier?(modifier)

          case final
          when "C"
            @editor_state.move_to_next_word unless editor_search_active?
          when "D"
            @editor_state.move_to_previous_word unless editor_search_active?
          when "F"
            @editor_state.move_line_end unless editor_search_active?
          when "H"
            @editor_state.move_line_start unless editor_search_active?
          else
            false
          end
        elsif (match = key.to_s.match(/\A\e\[3;(\d+)~\z/))
          if alt_modifier?(match[1].to_i)
            @editor_state.delete_word_after_cursor unless editor_search_active?
          else
            @editor_state.delete_at_cursor unless editor_search_active?
          end
        else
          false
        end
      end

      def handle_editor_bracketed_paste_key(key)
        paste = read_bracketed_paste(key)
        return false unless paste

        @editor_state.insert(normalize_paste(paste[:content])) unless editor_search_active?
        queue_pending_keys(paste[:remaining]) if paste[:remaining] && !paste[:remaining].empty?
        true
      end

      def ctrl_code(code)
        value = code.to_i
        return value if value < 32

        value.chr.downcase.ord
      rescue StandardError
        code
      end

      def handle_editor_named_key(key_name)
        return false unless key_name

        if editor_search_active?
          case key_name
          when :return, :enter
            editor_search_confirm
          when :backspace
            editor_search_delete_character
          else
            false
          end
        else
          case key_name
          when :return, :enter
            editor_insert_newline
          when :backspace
            delete_editor_selection || editor_delete_before_cursor
          when :delete
            delete_editor_selection || @editor_state.delete_at_cursor
          when :left
            @editor_state.move_left
          when :right
            @editor_state.move_right
          when :up
            @editor_state.move_up
          when :down
            @editor_state.move_down
          when :home
            @editor_state.move_line_start
          when :end
            @editor_state.move_line_end
          when :pageup
            scroll_editor_up(editor_scroll_page_rows)
          when :pagedown
            scroll_editor_down(editor_scroll_page_rows)
          else
            false
          end
        end
      end

      def editor_extending_selection
        @editor_state.selection_anchor ||= @editor_state.cursor
        yield
        true
      end

      def editor_selection_active?
        @editor_state&.selection_active?
      end

      def clear_editor_selection_before_edit
        @editor_state&.clear_selection
      end

      def delete_editor_selection
        range = @editor_state.selection_range
        return false unless range

        @editor_state.replace_range(range[0], range[1], "")
        true
      end

      def copy_editor_selection
        text = @editor_state.selected_text
        return false if text.empty?

        @editor_state.copy_range(*@editor_state.selection_range)
        @output_io.print("\e]52;c;#{Base64.strict_encode64(text)}\a")
        @output_io.flush if @output_io.respond_to?(:flush)
        @editor_state.clear_selection
        @editor_state.status = "Copied selection"
        true
      end

      def cut_editor_selection
        range = @editor_state.selection_range
        return false unless range

        @editor_state.cut_range(range[0], range[1])
        @editor_state.status = "Cut selection"
        true
      end

      def editor_search_active?
        @editor_state&.search_active
      end

      def editor_search_begin(direction = :forward)
        @editor_state.begin_search(direction)
        true
      end

      def editor_search_append(text)
        @editor_state.append_search(text)
        true
      end

      def editor_search_delete_character
        @editor_state.delete_search_character
        true
      end

      def editor_search_confirm
        @editor_state.confirm_search
        true
      end

      def editor_search_cancel
        @editor_state.cancel_search
        true
      end

      def editor_search_repeat(direction = nil)
        direction ||= @editor_state.search_direction
        @editor_state.repeat_search(direction)
        true
      end

      def editor_search_word_under_cursor(direction = :forward)
        query = @editor_state.word_under_cursor
        if query.empty?
          @editor_state.status = "No word under cursor"
          return true
        end

        @editor_state.repeat_search(direction, query)
        true
      end

      def editor_page_rows
        [[screen_height - 6, 1].max, 10].min
      end

      def editor_scroll_page_rows
        [editor_visible_line_count / 2, 1].max
      end

      def scroll_editor_up(rows)
        visible_count = editor_visible_line_count
        @editor_state.viewport_row = [@editor_state.viewport_row - rows.to_i, 0].max
        keep_editor_cursor_in_view(visible_count)
      end

      def scroll_editor_down(rows)
        visible_count = editor_visible_line_count
        last_top_row = [@editor_state.lines.length - visible_count, 0].max
        @editor_state.viewport_row = [@editor_state.viewport_row + rows.to_i, last_top_row].min
        keep_editor_cursor_in_view(visible_count)
      end

      def keep_editor_cursor_in_view(visible_count)
        line, column = @editor_state.cursor_line_and_column
        top_line = @editor_state.viewport_row
        bottom_line = top_line + visible_count - 1

        if line < top_line
          @editor_state.set_cursor_line_and_column(top_line, column)
        elsif line > bottom_line
          @editor_state.set_cursor_line_and_column(bottom_line, column)
        end
        true
      end

      def quit_editor(message = "Unsaved changes. Press Ctrl+Q again to discard.")
        return false unless @editor_state
        return close_editor unless @editor_state.dirty?
        return close_editor if @editor_state.quit_confirmed

        @editor_state.quit_confirmed = true
        @editor_state.status = message
        true
      end

      def save_editor
        return false unless @editor_state

        if @editor_state.file_changed_on_disk? && !@editor_state.overwrite_confirmed
          @editor_state.overwrite_confirmed = true
          @editor_state.status = "File changed on disk. Press Ctrl+S again to overwrite."
          return true
        end

        File.write(@editor_state.path, @editor_state.buffer)
        @editor_state.refresh_after_save(@editor_state.buffer)
        true
      rescue StandardError => e
        @editor_state.status = "Save failed: #{e.message}" if @editor_state
        false
      end

      def printable_key?(key)
        key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)
      end
    end
  end
end
