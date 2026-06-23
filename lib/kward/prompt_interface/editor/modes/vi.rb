# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Vi-style keymap for the built-in composer file editor.
    module ViEditorMode
      private

      def handle_vi_key(key)
        csi_result = handle_vi_csi_u_key(key)
        return csi_result unless csi_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        return handle_vi_search_key(key) if editor_search_active?
        return handle_vi_command_key(key) if @editor_state.vi_mode == "command"
        return handle_vi_insert_key(key) if @editor_state.vi_mode == "insert"
        return handle_vi_replace_key(key) if @editor_state.vi_mode == "replace"
        return handle_vi_visual_key(key) if vi_visual_mode?

        handle_vi_normal_key(key)
      end

      def handle_vi_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        normalized_code = code.to_i.chr.downcase.ord rescue code
        return false unless code == 27 || (ctrl_modifier?(modifier) && normalized_code == 99)

        return editor_search_cancel if editor_search_active?

        @editor_state.vi_command = ""
        @editor_state.vi_pending = ""
        @editor_state.clear_selection
        vi_return_to_normal
      end

      def handle_vi_search_key(key)
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

      def handle_vi_insert_key(key)
        return if handle_editor_bracketed_paste_key(key)

        case key
        when "\e", "\x03", :escape
          vi_return_to_normal
        when "\b", "\x7F"
          vi_record_undo { @editor_state.delete_before_cursor }
        when "\n", "\r"
          vi_record_undo { @editor_state.insert("\n") }
        else
          key_name = key_name_for(key)
          named_result = handle_vi_insert_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          vi_record_undo { @editor_state.insert(key) } if printable_key?(key)
        end
      end

      def handle_vi_insert_named_key(key_name)
        case key_name
        when :escape
          vi_return_to_normal
        when :return, :enter
          vi_record_undo { @editor_state.insert("\n") }
        when :backspace
          vi_record_undo { @editor_state.delete_before_cursor }
        when :delete
          vi_record_undo { @editor_state.delete_at_cursor }
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

      def handle_vi_replace_key(key)
        return if handle_editor_bracketed_paste_key(key)

        case key
        when "\e", "\x03", :escape
          vi_return_to_normal
        when "\b", "\x7F"
          vi_record_undo { @editor_state.delete_before_cursor }
        when "\n", "\r"
          vi_record_undo { @editor_state.insert("\n") }
        else
          key_name = key_name_for(key)
          named_result = handle_vi_insert_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          vi_record_undo { vi_replace_character(key) } if printable_key?(key)
        end
      end

      def vi_replace_character(key)
        @editor_state.delete_at_cursor
        @editor_state.insert(key)
      end

      def handle_vi_command_key(key)
        case key
        when "\e", "\x03", :escape
          @editor_state.vi_command = ""
          vi_return_to_normal
        when "\b", "\x7F"
          @editor_state.vi_command = @editor_state.vi_command[0...-1].to_s
          @editor_state.status = ":#{@editor_state.vi_command}"
        when "\n", "\r"
          execute_vi_command(@editor_state.vi_command)
        else
          if printable_key?(key)
            @editor_state.vi_command = @editor_state.vi_command.to_s + key
            @editor_state.status = ":#{@editor_state.vi_command}"
          end
        end
        true
      end

      def execute_vi_command(command)
        command = command.to_s.strip
        @editor_state.vi_mode = "normal"
        @editor_state.vi_command = ""
        case command
        when "w"
          save_editor
        when "q"
          vi_quit_editor
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

      def vi_quit_editor
        return close_editor unless @editor_state.dirty?

        @editor_state.status = "No write since last change (:q! overrides)"
        true
      end

      def handle_vi_normal_key(key)
        if key == "\e" || key == "\x03"
          @editor_state.vi_pending = ""
          vi_return_to_normal
          return true
        end

        key_name = key_name_for(key)
        named_result = handle_vi_named_key(key_name) if key_name
        return named_result unless named_result == false || named_result.nil?
        return false unless key.is_a?(String)
        return true unless printable_key?(key) || vi_normal_control_key?(key)

        pending = @editor_state.vi_pending.to_s + key
        if vi_waiting_for_more?(pending)
          @editor_state.vi_pending = pending
          @editor_state.status = "NORMAL #{pending}"
          return true
        end

        @editor_state.vi_pending = ""
        execute_vi_normal_command(pending)
        true
      end

      def handle_vi_named_key(key_name)
        case key_name
        when :escape
          @editor_state.vi_pending = ""
          vi_return_to_normal
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
          vi_move_to_relative_line_first_non_blank(1)
        when :ctrl_b
          @editor_state.page_up(editor_page_rows)
        when :ctrl_f
          @editor_state.page_down(editor_page_rows)
        when :ctrl_d
          @editor_state.page_down(vi_half_page_rows)
        when :ctrl_u
          @editor_state.page_up(vi_half_page_rows)
        when :ctrl_e
          vi_scroll_down
        when :ctrl_y
          vi_scroll_up
        else
          false
        end
      end

      def vi_normal_control_key?(key)
        ["\n", "\r", "\b", "\x7F", "\x02", "\x04", "\x05", "\x06", "\x15", "\x19"].include?(key)
      end

      def vi_visual_mode?
        %w[visual visual_line].include?(@editor_state.vi_mode)
      end

      def vi_return_to_normal
        @editor_state.vi_mode = "normal"
        @editor_state.status = "NORMAL · i insert · :w save · :q quit"
        true
      end

      def vi_cancel_visual_mode
        @editor_state.vi_pending = ""
        @editor_state.clear_selection
        vi_return_to_normal
      end

      def vi_waiting_for_more?(command)
        return true if command.match?(/\A\d+\z/) && command != "0"
        return true if command.match?(/\A\d*g\z/)
        return true if command.match?(/\A\d*[dy]\d*\z/)

        false
      end

      def execute_vi_normal_command(command)
        count, body = vi_count_and_body(command)
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
          vi_move_to_relative_line_first_non_blank(count)
        when "-"
          vi_move_to_relative_line_first_non_blank(-count)
        when "_"
          vi_move_to_relative_line_first_non_blank(count - 1)
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
          vi_move_to_screen_line(count - 1)
        when "M"
          vi_move_to_screen_line(editor_page_rows / 2)
        when "L"
          vi_move_to_screen_line(editor_page_rows - count)
        when "\x06"
          @editor_state.page_down(editor_page_rows)
        when "\x02"
          @editor_state.page_up(editor_page_rows)
        when "\x04"
          @editor_state.page_down(vi_half_page_rows)
        when "\x15"
          @editor_state.page_up(vi_half_page_rows)
        when "\x05"
          vi_scroll_down
        when "\x19"
          vi_scroll_up
        when "i"
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "I"
          @editor_state.move_line_first_non_blank
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "a"
          @editor_state.move_right
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "A"
          @editor_state.move_line_end
          @editor_state.vi_mode = "insert"
          @editor_state.status = "INSERT · Esc normal"
        when "R"
          @editor_state.vi_mode = "replace"
          @editor_state.status = "REPLACE · Esc normal"
        when "v"
          vi_begin_visual_mode("visual")
        when "V"
          vi_begin_visual_mode("visual_line")
        when "o"
          vi_open_line_below
        when "O"
          vi_open_line_above
        when "x"
          vi_record_undo { count.times { @editor_state.delete_at_cursor } }
        when "dd"
          vi_delete_lines(count)
        when "yy"
          vi_yank_lines(count)
        when "p"
          vi_record_undo { @editor_state.insert(@editor_state.kill_buffer) }
        when "u"
          @editor_state.undo
        when ":"
          @editor_state.vi_mode = "command"
          @editor_state.vi_command = ""
          @editor_state.status = ":"
        when "/"
          editor_search_begin
        else
          if body.start_with?("d") || body.start_with?("y")
            vi_operator_motion(body[0], body[1..], count)
          else
            @editor_state.status = "Unknown command: #{command}"
          end
        end
      end

      def handle_vi_visual_key(key)
        key_name = key_name_for(key)
        return handle_vi_visual_named_key(key_name) if key_name
        if key == "\e" || key == "\x03"
          vi_cancel_visual_mode
          return true
        end
        return true unless printable_key?(key)

        case key
        when "y"
          vi_yank_visual_selection
        when "d", "x"
          vi_delete_visual_selection
        when "c"
          vi_change_visual_selection
        when "p"
          vi_paste_visual_selection
        else
          vi_move_visual_selection(key)
        end
        true
      end

      def handle_vi_visual_named_key(key_name)
        case key_name
        when :escape
          vi_cancel_visual_mode
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

      def vi_begin_visual_mode(mode)
        @editor_state.clear_selection
        @editor_state.selection_anchor = @editor_state.cursor
        @editor_state.vi_mode = mode
        @editor_state.status = mode == "visual_line" ? "VISUAL LINE" : "VISUAL"
        true
      end

      def vi_move_visual_selection(key)
        count, body = vi_count_and_body(key)
        count = 1 if count.zero?
        vi_apply_motion(body, count)
      end

      def vi_visual_range
        @editor_state.selection_range
      end

      def vi_yank_visual_selection
        range = vi_visual_range
        return false unless range

        vi_copy_range(range[0], range[1], "Yanked selection")
        vi_cancel_visual_mode
      end

      def vi_delete_visual_selection
        range = vi_visual_range
        return false unless range

        @editor_state.copy_range(range[0], range[1])
        vi_record_undo { @editor_state.replace_range(range[0], range[1], "") }
        vi_cancel_visual_mode
      end

      def vi_change_visual_selection
        range = vi_visual_range
        return false unless range

        @editor_state.copy_range(range[0], range[1])
        vi_record_undo { @editor_state.replace_range(range[0], range[1], "") }
        @editor_state.clear_selection
        @editor_state.vi_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vi_paste_visual_selection
        range = vi_visual_range
        return false unless range

        text = @editor_state.kill_buffer.to_s
        vi_record_undo { @editor_state.replace_range(range[0], range[1], text) }
        vi_cancel_visual_mode
      end

      def vi_count_and_body(command)
        match = command.match(/\A(\d*)(.*)\z/)
        [match[1].to_i, match[2]]
      end

      def vi_move_to_relative_line_first_non_blank(offset)
        line, = @editor_state.cursor_line_and_column
        @editor_state.move_to_line_first_non_blank(line + offset)
      end

      def vi_move_to_screen_line(offset)
        @editor_state.move_to_line_first_non_blank(@editor_state.viewport_row + offset)
      end

      def vi_half_page_rows
        [editor_page_rows / 2, 1].max
      end

      def vi_scroll_down
        @editor_state.viewport_row = [@editor_state.viewport_row + 1, @editor_state.lines.length - 1].min
        line, column = @editor_state.cursor_line_and_column
        @editor_state.set_cursor_line_and_column(@editor_state.viewport_row, column) if line < @editor_state.viewport_row
      end

      def vi_scroll_up
        @editor_state.viewport_row = [@editor_state.viewport_row - 1, 0].max
        bottom_line = @editor_state.viewport_row + editor_page_rows - 1
        line, column = @editor_state.cursor_line_and_column
        @editor_state.set_cursor_line_and_column(bottom_line, column) if line > bottom_line
      end

      def vi_open_line_below
        line, = @editor_state.cursor_line_and_column
        line_end = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
        vi_record_undo do
          @editor_state.cursor = line_end
          @editor_state.insert("\n")
        end
        @editor_state.vi_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vi_open_line_above
        line, = @editor_state.cursor_line_and_column
        start_index = @editor_state.line_start_offset(line)
        vi_record_undo do
          @editor_state.cursor = start_index
          @editor_state.insert("\n")
          @editor_state.cursor = start_index
        end
        @editor_state.vi_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vi_delete_lines(count)
        start_index, end_index = vi_linewise_delete_range(count)
        @editor_state.copy_range(start_index, end_index)
        vi_record_undo { @editor_state.replace_range(start_index, end_index, "") }
        @editor_state.status = "Deleted #{count} line#{count == 1 ? "" : "s"}"
      end

      def vi_linewise_delete_range(count)
        line, = @editor_state.cursor_line_and_column
        start_index, = @editor_state.line_range(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        _, end_index = @editor_state.line_range(end_line)
        if end_index == @editor_state.buffer.length && start_index.positive?
          start_index -= 1
        end
        [start_index, end_index]
      end

      def vi_yank_lines(count)
        line, = @editor_state.cursor_line_and_column
        start_index, = @editor_state.line_range(line)
        end_line = [line + count - 1, @editor_state.lines.length - 1].min
        _, end_index = @editor_state.line_range(end_line)
        vi_copy_range(start_index, end_index, "Yanked #{count} line#{count == 1 ? "" : "s"}")
      end

      def vi_operator_motion(operator, motion, count)
        motion_count, motion = vi_count_and_body(motion)
        count = motion_count if motion_count.positive?
        start_index = @editor_state.cursor
        vi_apply_motion(motion, count)
        end_index = @editor_state.cursor
        if motion == "$" || motion == "e"
          end_index = [end_index + 1, @editor_state.buffer.length].min
        end
        return @editor_state.status = "Empty range" if start_index == end_index

        if operator == "d"
          @editor_state.copy_range(start_index, end_index)
          vi_record_undo { @editor_state.replace_range(start_index, end_index, "") }
          @editor_state.status = "Deleted"
        else
          vi_copy_range(start_index, end_index, "Yanked")
          @editor_state.cursor = start_index
        end
      end

      def vi_apply_motion(motion, count)
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
          vi_move_to_relative_line_first_non_blank(count)
        when "-"
          vi_move_to_relative_line_first_non_blank(-count)
        when "_"
          vi_move_to_relative_line_first_non_blank(count - 1)
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

      def vi_copy_range(start_index, end_index, status)
        @editor_state.copy_range(start_index, end_index)
        @output_io.print("\e]52;c;#{Base64.strict_encode64(@editor_state.kill_buffer)}\a")
        @output_io.flush if @output_io.respond_to?(:flush)
        @editor_state.status = status
      end

      def vi_record_undo
        before = @editor_state.buffer.dup
        @editor_state.push_undo
        yield
        @editor_state.undo_stack.pop if @editor_state.buffer == before
      end

    end
  end
end
