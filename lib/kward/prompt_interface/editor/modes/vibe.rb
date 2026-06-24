# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Vibe-style keymap for the built-in composer file editor.
    module VibeEditorMode
      private

      def handle_vibe_key(key)
        csi_result = handle_vibe_csi_u_key(key)
        return csi_result unless csi_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        return handle_vibe_repeat_change if key == "." && @editor_state.vibe_mode == "normal"
        return handle_vibe_search_key(key) if editor_search_active?
        return handle_vibe_command_key(key) if @editor_state.vibe_mode == "command"
        return handle_vibe_insert_key(key) if @editor_state.vibe_mode == "insert"
        return handle_vibe_replace_key(key) if @editor_state.vibe_mode == "replace"
        return handle_vibe_visual_key(key) if vibe_visual_mode?

        handle_vibe_normal_key(key)
      end

      def handle_vibe_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        normalized_code = code.to_i.chr.downcase.ord rescue code
        text = csi_u_text(sequence)
        if !text.empty?
          return editor_search_append(text) if editor_search_active?
          return vibe_record_undo { editor_insert_printable(text) } if @editor_state.vibe_mode == "insert"
          return vibe_record_undo { vibe_replace_character(text) } if @editor_state.vibe_mode == "replace"
        end
        return false unless code == 27 || (ctrl_modifier?(modifier) && normalized_code == 99)

        return editor_search_cancel if editor_search_active?

        @editor_state.vibe_command = ""
        @editor_state.vibe_pending = ""
        @editor_state.clear_selection
        vibe_return_to_normal
      end

      def handle_vibe_search_key(key)
        case key
        when "\n", "\r"
          editor_search_confirm
        when "\b", "\x7F"
          editor_search_delete_character
        when "\e", "\x03"
          editor_search_cancel
        else
          editor_search_append(key) if printable_key?(key)
        end
        true
      end

      def handle_vibe_insert_key(key)
        return if handle_editor_bracketed_paste_key(key)

        vibe_record_insert_change_key(key)
        case key
        when "\e", "\x03", :escape
          vibe_return_to_normal
        when "\b", "\x7F"
          vibe_record_undo { editor_delete_before_cursor }
        when "\n", "\r"
          vibe_record_undo { editor_insert_newline }
        else
          key_name = key_name_for(key)
          named_result = handle_vibe_insert_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          vibe_record_undo { editor_insert_printable(key) } if printable_key?(key)
        end
      end

      def handle_vibe_insert_named_key(key_name)
        case key_name
        when :escape
          vibe_return_to_normal
        when :return, :enter
          vibe_record_undo { editor_insert_newline }
        when :backspace
          vibe_record_undo { editor_delete_before_cursor }
        when :delete
          vibe_record_undo { @editor_state.delete_at_cursor }
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          @editor_state.move_up
        when :down
          @editor_state.move_down
        else
          false
        end
      end

      def handle_vibe_replace_key(key)
        return if handle_editor_bracketed_paste_key(key)

        vibe_record_insert_change_key(key)
        case key
        when "\e", "\x03", :escape
          vibe_return_to_normal
        when "\b", "\x7F"
          vibe_record_undo { editor_delete_before_cursor }
        when "\n", "\r"
          vibe_record_undo { editor_insert_newline }
        else
          key_name = key_name_for(key)
          named_result = handle_vibe_insert_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          vibe_record_undo { vibe_replace_character(key) } if printable_key?(key)
        end
      end

      def vibe_replace_character(key)
        @editor_state.delete_at_cursor
        editor_insert_printable(key)
      end

      def handle_vibe_command_key(key)
        case key
        when "\e", "\x03", :escape
          @editor_state.vibe_command = ""
          vibe_return_to_normal
        when "\b", "\x7F"
          @editor_state.vibe_command = @editor_state.vibe_command[0...-1].to_s
          @editor_state.status = ":#{@editor_state.vibe_command}"
        when "\n", "\r"
          execute_vibe_command(@editor_state.vibe_command)
        else
          if printable_key?(key)
            @editor_state.vibe_command = @editor_state.vibe_command.to_s + key
            @editor_state.status = ":#{@editor_state.vibe_command}"
          end
        end
        true
      end

      def execute_vibe_command(command)
        command = command.to_s.strip
        @editor_state.vibe_mode = "normal"
        @editor_state.vibe_command = ""
        case command
        when "w"
          save_editor
        when "q"
          vibe_quit_editor
        when "q!"
          close_editor
        when "wq"
          save_editor && close_editor
        when "x"
          save_editor if @editor_state&.dirty?
          close_editor if @editor_state
        when /\A\d+\z/
          @editor_state.set_cursor_line_and_column(command.to_i - 1, 0)
          @editor_state.status = "Line #{command}"
        else
          @editor_state.status = "Unknown command: #{command}"
        end
        true
      end

      def vibe_quit_editor
        return close_editor unless @editor_state.dirty?

        @editor_state.status = "No write since last change (:q! overrides)"
        true
      end

      def handle_vibe_normal_key(key)
        if key == "\e" || key == "\x03"
          @editor_state.vibe_pending = ""
          vibe_return_to_normal
          return true
        end

        key_name = key_name_for(key)
        named_result = handle_vibe_named_key(key_name) if key_name
        return named_result unless named_result == false || named_result.nil?
        return false unless key.is_a?(String)
        return true unless printable_key?(key) || vibe_normal_control_key?(key)

        pending = @editor_state.vibe_pending.to_s + key
        if vibe_waiting_for_more?(pending)
          @editor_state.vibe_pending = pending
          @editor_state.status = "NORMAL #{pending}"
          return true
        end

        @editor_state.vibe_pending = ""
        execute_vibe_normal_command(pending)
        true
      end

      def handle_vibe_named_key(key_name)
        case key_name
        when :escape
          @editor_state.vibe_pending = ""
          vibe_return_to_normal
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          @editor_state.move_up
        when :down
          @editor_state.move_down
        when :backspace
          @editor_state.move_left
        when :return, :enter
          vibe_move_to_relative_line_first_non_blank(1)
        when :ctrl_b
          @editor_state.page_up(editor_page_rows)
        when :ctrl_f
          @editor_state.page_down(editor_page_rows)
        when :ctrl_d
          @editor_state.page_down(vibe_half_page_rows)
        when :ctrl_u
          @editor_state.page_up(vibe_half_page_rows)
        when :ctrl_e
          vibe_scroll_down
        when :ctrl_y
          vibe_scroll_up
        when :ctrl_r
          @editor_state.redo
        else
          false
        end
      end

      def vibe_normal_control_key?(key)
        ["\n", "\r", "\b", "\x7F", "\x02", "\x04", "\x05", "\x06", "\x12", "\x15", "\x19"].include?(key)
      end

      def vibe_visual_mode?
        %w[visual visual_line].include?(@editor_state.vibe_mode)
      end

      def vibe_return_to_normal
        @editor_state.vibe_mode = "normal"
        @editor_state.status = "NORMAL · i insert · :w save · :q quit"
        true
      end

      def vibe_cancel_visual_mode
        @editor_state.vibe_pending = ""
        @editor_state.clear_selection
        vibe_return_to_normal
      end

      def vibe_waiting_for_more?(command)
        return true if command.match?(/\A\d+\z/) && command != "0"
        return true if command.match?(/\A\d*g\z/)
        return true if command.match?(/\A\d*[cdy]\d*\z/)
        return true if command.match?(/\A\d*r\z/)

        false
      end

      def execute_vibe_normal_command(command)
        count, body = vibe_count_and_body(command)
        count = 1 if count.zero?
        case body
        when "h", "\b", "\x7F"
          count.times { @editor_state.move_left }
        when "j"
          count.times { @editor_state.move_down }
        when "k"
          count.times { @editor_state.move_up }
        when "l", " "
          count.times { @editor_state.move_right }
        when "0"
          @editor_state.move_line_start
        when "^"
          @editor_state.move_line_first_non_blank
        when "+", "\n", "\r"
          vibe_move_to_relative_line_first_non_blank(count)
        when "-"
          vibe_move_to_relative_line_first_non_blank(-count)
        when "_"
          vibe_move_to_relative_line_first_non_blank(count - 1)
        when "$"
          @editor_state.move_line_end
        when "w"
          count.times { @editor_state.move_to_next_word }
        when "e"
          count.times { @editor_state.move_to_word_end }
        when "b"
          count.times { @editor_state.move_to_previous_word }
        when "gg"
          @editor_state.move_file_start
        when "G"
          line = command.match?(/\A\d+G\z/) ? count - 1 : @editor_state.lines.length - 1
          @editor_state.set_cursor_line_and_column(line, 0)
        when "H"
          vibe_move_to_screen_line(count - 1)
        when "M"
          vibe_move_to_screen_line(editor_page_rows / 2)
        when "L"
          vibe_move_to_screen_line(editor_page_rows - count)
        when "\x06"
          @editor_state.page_down(editor_page_rows)
        when "\x02"
          @editor_state.page_up(editor_page_rows)
        when "\x04"
          @editor_state.page_down(vibe_half_page_rows)
        when "\x15"
          @editor_state.page_up(vibe_half_page_rows)
        when "\x05"
          vibe_scroll_down
        when "\x19"
          vibe_scroll_up
        when "\x12"
          @editor_state.redo
        when "i"
          vibe_enter_insert_mode(command)
        when "I"
          @editor_state.move_line_first_non_blank
          vibe_enter_insert_mode(command)
        when "a"
          @editor_state.move_right
          vibe_enter_insert_mode(command)
        when "A"
          @editor_state.move_line_end
          vibe_enter_insert_mode(command)
        when "C"
          vibe_change_to_line_end(command)
        when "D"
          vibe_delete_to_line_end(command)
        when "R"
          @editor_state.vibe_mode = "replace"
          @editor_state.status = "REPLACE · Esc normal"
          vibe_begin_change_recording(command)
        when "s"
          vibe_substitute_characters(count, command)
        when "S"
          vibe_change_lines(count, command)
        when "J"
          vibe_join_lines(count, command)
        when "n"
          editor_search_repeat
        when "N"
          editor_search_repeat(vibe_opposite_search_direction)
        when "*"
          editor_search_word_under_cursor(:forward)
        when "#"
          editor_search_word_under_cursor(:backward)
        when "U"
          vibe_restore_current_line
        when /^r(.?)$/
          vibe_replace_single_character(Regexp.last_match(1), count, command)
        when "v"
          vibe_begin_visual_mode("visual")
        when "V"
          vibe_begin_visual_mode("visual_line")
        when "o"
          vibe_open_line_below
        when "O"
          vibe_open_line_above
        when "x"
          vibe_record_undo { count.times { @editor_state.delete_at_cursor } }
          vibe_remember_change(command)
        when "X"
          vibe_record_undo { count.times { @editor_state.delete_before_cursor } }
          vibe_remember_change(command)
        when "dd"
          vibe_delete_lines(count)
          vibe_remember_change(command)
        when "cc"
          vibe_change_lines(count, command)
        when "yy"
          vibe_yank_lines(count)
        when "p"
          vibe_record_undo { @editor_state.insert(@editor_state.kill_buffer) }
          vibe_remember_change(command)
        when "P"
          vibe_paste_before(command)
        when "u"
          @editor_state.undo
        when ":"
          @editor_state.vibe_mode = "command"
          @editor_state.vibe_command = ""
          @editor_state.status = ":"
        when "/"
          editor_search_begin
        when "?"
          editor_search_begin(:backward)
        else
          if body.start_with?("d") || body.start_with?("y") || body.start_with?("c")
            vibe_operator_motion(body[0], body[1..], count, command)
          else
            @editor_state.status = "Unknown command: #{command}"
          end
        end
      end

      def handle_vibe_visual_key(key)
        key_name = key_name_for(key)
        return handle_vibe_visual_named_key(key_name) if key_name
        if key == "\e" || key == "\x03"
          vibe_cancel_visual_mode
          return true
        end
        return true unless printable_key?(key)

        case key
        when *EditorAutoClosePairs::AUTO_CLOSE_OPENERS
          vibe_record_undo { editor_insert_printable(key) }
          vibe_return_to_normal
        when "y"
          vibe_yank_visual_selection
        when "d", "x"
          vibe_delete_visual_selection
        when "c"
          vibe_change_visual_selection
        when "p"
          vibe_paste_visual_selection
        else
          vibe_move_visual_selection(key)
        end
        true
      end

      def handle_vibe_visual_named_key(key_name)
        case key_name
        when :escape
          vibe_cancel_visual_mode
        when :left
          @editor_state.move_left
        when :right
          @editor_state.move_right
        when :up
          @editor_state.move_up
        when :down
          @editor_state.move_down
        else
          false
        end
      end

      def vibe_begin_visual_mode(mode)
        @editor_state.clear_selection
        @editor_state.selection_anchor = @editor_state.cursor
        @editor_state.vibe_mode = mode
        @editor_state.status = mode == "visual_line" ? "VISUAL LINE" : "VISUAL"
        true
      end

      def vibe_move_visual_selection(key)
        count, body = vibe_count_and_body(key)
        count = 1 if count.zero?
        vibe_apply_motion(body, count)
      end

      def vibe_visual_range
        @editor_state.selection_range
      end

      def vibe_yank_visual_selection
        range = vibe_visual_range
        return false unless range

        vibe_copy_range(range[0], range[1], "Yanked selection")
        vibe_cancel_visual_mode
      end

      def vibe_delete_visual_selection
        range = vibe_visual_range
        return false unless range

        @editor_state.copy_range(range[0], range[1])
        vibe_record_undo { @editor_state.replace_range(range[0], range[1], "") }
        vibe_cancel_visual_mode
      end

      def vibe_change_visual_selection
        range = vibe_visual_range
        return false unless range

        @editor_state.copy_range(range[0], range[1])
        vibe_record_undo { @editor_state.replace_range(range[0], range[1], "") }
        @editor_state.clear_selection
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vibe_paste_visual_selection
        range = vibe_visual_range
        return false unless range

        text = @editor_state.kill_buffer.to_s
        vibe_record_undo { @editor_state.replace_range(range[0], range[1], text) }
        vibe_cancel_visual_mode
      end

      def vibe_count_and_body(command)
        match = command.match(/\A(\d*)(.*)\z/)
        [match[1].to_i, match[2]]
      end

      def vibe_move_to_relative_line_first_non_blank(offset)
        line, = @editor_state.cursor_line_and_column
        @editor_state.move_to_line_first_non_blank(line + offset)
      end

      def vibe_move_to_screen_line(offset)
        @editor_state.move_to_line_first_non_blank(@editor_state.viewport_row + offset)
      end

      def vibe_half_page_rows
        [editor_page_rows / 2, 1].max
      end

      def vibe_scroll_down
        @editor_state.viewport_row = [@editor_state.viewport_row + 1, @editor_state.lines.length - 1].min
        line, column = @editor_state.cursor_line_and_column
        @editor_state.set_cursor_line_and_column(@editor_state.viewport_row, column) if line < @editor_state.viewport_row
      end

      def vibe_scroll_up
        @editor_state.viewport_row = [@editor_state.viewport_row - 1, 0].max
        bottom_line = @editor_state.viewport_row + editor_page_rows - 1
        line, column = @editor_state.cursor_line_and_column
        @editor_state.set_cursor_line_and_column(bottom_line, column) if line > bottom_line
      end

      def vibe_open_line_below
        line, = @editor_state.cursor_line_and_column
        line_end = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
        vibe_record_undo do
          @editor_state.cursor = line_end
          @editor_state.insert("\n")
        end
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vibe_open_line_above
        line, = @editor_state.cursor_line_and_column
        start_index = @editor_state.line_start_offset(line)
        vibe_record_undo do
          @editor_state.cursor = start_index
          @editor_state.insert("\n")
          @editor_state.cursor = start_index
        end
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vibe_paste_before(command = nil)
        text = @editor_state.kill_buffer.to_s
        return false if text.empty?

        vibe_record_undo do
          @editor_state.cursor = @editor_state.current_line_range.first if text.end_with?("\n")
          @editor_state.insert(text)
        end
        vibe_remember_change(command)
      end

      def vibe_delete_lines(count)
        start_index, end_index = vibe_linewise_delete_range(count)
        @editor_state.copy_range(start_index, end_index)
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        @editor_state.status = "Deleted #{count} line#{count == 1 ? "" : "s"}"
      end

      def vibe_linewise_delete_range(count)
        line, = @editor_state.cursor_line_and_column
        start_index, = @editor_state.line_range(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        _, end_index = @editor_state.line_range(end_line)
        if end_index == @editor_state.buffer.length && start_index.positive?
          start_index -= 1
        end
        [start_index, end_index]
      end

      def vibe_yank_lines(count)
        line, = @editor_state.cursor_line_and_column
        start_index, = @editor_state.line_range(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        _, end_index = @editor_state.line_range(end_line)
        vibe_copy_range(start_index, end_index, "Yanked #{count} line#{count == 1 ? "" : "s"}")
      end

      def vibe_change_lines(count, command = nil)
        start_index, end_index = vibe_linewise_change_range(count)
        @editor_state.copy_range(start_index, end_index)
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        @editor_state.cursor = start_index
        vibe_enter_insert_mode(command)
      end

      def vibe_linewise_change_range(count)
        line, = @editor_state.cursor_line_and_column
        start_index = @editor_state.line_start_offset(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        end_index = @editor_state.line_start_offset(end_line) + @editor_state.lines[end_line].to_s.length
        [start_index, end_index]
      end

      def vibe_change_to_line_end(command = nil)
        start_index = @editor_state.cursor
        line, = @editor_state.cursor_line_and_column
        end_index = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
        return vibe_enter_insert_mode(command) if start_index == end_index

        @editor_state.copy_range(start_index, end_index)
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        vibe_enter_insert_mode(command)
      end

      def vibe_delete_to_line_end(command = nil)
        start_index = @editor_state.cursor
        line, = @editor_state.cursor_line_and_column
        end_index = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
        return @editor_state.status = "Empty range" if start_index == end_index

        @editor_state.copy_range(start_index, end_index)
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        @editor_state.status = "Deleted"
        vibe_remember_change(command)
      end

      def vibe_substitute_characters(count, command = nil)
        start_index = @editor_state.cursor
        end_index = [start_index + count, @editor_state.buffer.length].min
        @editor_state.copy_range(start_index, end_index)
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        vibe_enter_insert_mode(command)
      end

      def vibe_replace_single_character(character, count, command = nil)
        return @editor_state.status = "Replacement character required" if character.to_s.empty?

        vibe_record_undo do
          count.times do
            @editor_state.delete_at_cursor
            @editor_state.insert(character)
          end
        end
        @editor_state.move_left
        vibe_remember_change(command)
      end

      def vibe_join_lines(count, command = nil)
        line, = @editor_state.cursor_line_and_column
        join_count = [count, 2].max
        end_line = [line + join_count - 1, @editor_state.lines.length - 1].min
        return @editor_state.status = "Already at last line" if end_line == line

        vibe_record_undo do
          (end_line - line).times do
            line_end = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
            next_line_start = line_end + 1
            next_line_end = next_line_start + @editor_state.lines[line + 1].to_s.length
            next_line = @editor_state.buffer[next_line_start...next_line_end].to_s.sub(/\A\s+/, "")
            separator = next_line.empty? ? "" : " "
            @editor_state.replace_range(line_end, next_line_end, separator + next_line)
            @editor_state.cursor = line_end
          end
        end
        vibe_remember_change(command)
      end

      def vibe_enter_insert_mode(command = nil)
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
        vibe_begin_change_recording(command) if command
      end

      def vibe_operator_motion(operator, motion, count, command = nil)
        motion_count, motion = vibe_count_and_body(motion)
        count *= motion_count if motion_count.positive?
        return vibe_operator_linewise(operator, count, command) if motion == operator

        start_index = @editor_state.cursor
        vibe_apply_motion(motion, count)
        end_index = @editor_state.cursor
        end_index = [end_index + 1, @editor_state.buffer.length].min if motion == "e"
        return @editor_state.status = "Empty range" if start_index == end_index

        case operator
        when "d"
          @editor_state.copy_range(start_index, end_index)
          vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
          @editor_state.status = "Deleted"
          vibe_remember_change(command)
        when "c"
          @editor_state.copy_range(start_index, end_index)
          vibe_record_undo { @editor_state.replace_range(start_index, end_index, "") }
          vibe_enter_insert_mode(vibe_build_change_command(operator, motion, count, motion_count))
        else
          vibe_copy_range(start_index, end_index, "Yanked")
          @editor_state.cursor = start_index
        end
      end

      def vibe_operator_linewise(operator, count, command = nil)
        case operator
        when "d"
          vibe_delete_lines(count)
          vibe_remember_change(command)
        when "c"
          vibe_change_lines(count, command)
        else
          vibe_yank_lines(count)
        end
      end

      def vibe_apply_motion(motion, count)
        case motion
        when "w"
          count.times { @editor_state.move_to_next_word }
        when "e"
          count.times { @editor_state.move_to_word_end }
        when "b"
          count.times { @editor_state.move_to_previous_word }
        when "$"
          @editor_state.move_line_end
        when "0"
          @editor_state.move_line_start
        when "^"
          @editor_state.move_line_first_non_blank
        when "+", "\n", "\r"
          vibe_move_to_relative_line_first_non_blank(count)
        when "-"
          vibe_move_to_relative_line_first_non_blank(-count)
        when "_"
          vibe_move_to_relative_line_first_non_blank(count - 1)
        when "h", "\b", "\x7F"
          count.times { @editor_state.move_left }
        when "j"
          count.times { @editor_state.move_down }
        when "k"
          count.times { @editor_state.move_up }
        when "l", " "
          count.times { @editor_state.move_right }
        else
          @editor_state.status = "Unsupported motion: #{motion}"
        end
      end

      def vibe_copy_range(start_index, end_index, status)
        @editor_state.copy_range(start_index, end_index)
        @output_io.print("\e]52;c;#{Base64.strict_encode64(@editor_state.kill_buffer)}\a")
        @output_io.flush if @output_io.respond_to?(:flush)
        @editor_state.status = status
      end

      def vibe_opposite_search_direction
        @editor_state.search_direction == :backward ? :forward : :backward
      end

      def vibe_restore_current_line
        line, = @editor_state.cursor_line_and_column
        start_index = @editor_state.line_start_offset(line)
        end_index = start_index + @editor_state.lines[line].to_s.length
        original_line = @editor_state.original_content.split("\n", -1)[line].to_s
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, original_line) }
        @editor_state.status = "Restored line"
      end

      def handle_vibe_repeat_change
        change = @editor_state.vibe_last_change
        return @editor_state.status = "No change to repeat" unless change

        change.dup.each { |key| handle_vibe_key(key) }
        true
      end

      def vibe_begin_change_recording(command)
        @editor_state.vibe_last_change = vibe_change_keys(command)
      end

      def vibe_record_insert_change_key(key)
        return unless @editor_state.vibe_last_change
        return if ["\x03"].include?(key)

        @editor_state.vibe_last_change << key
      end

      def vibe_remember_change(command)
        @editor_state.vibe_last_change = vibe_change_keys(command) if command
      end

      def vibe_build_change_command(operator, motion, count, motion_count)
        command = +""
        command << count.to_s if count > 1 && motion_count.zero?
        command << operator
        command << motion_count.to_s if motion_count.positive?
        command << motion
        vibe_change_keys(command)
      end

      def vibe_change_keys(command)
        Array(command).flat_map { |key| key.is_a?(String) ? key.each_char.to_a : key }
      end

      def vibe_record_undo
        before = @editor_state.buffer.dup
        @editor_state.push_undo
        yield
        @editor_state.undo_stack.pop if @editor_state.buffer == before
      end

    end
  end
end
