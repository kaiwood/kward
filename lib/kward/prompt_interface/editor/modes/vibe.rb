# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Vibe-style keymap for the built-in composer file editor.
    module VibeEditorMode
      VIBE_SIMPLE_MOTION_KEYS = [
        "w", "e", "b", "$", "0", "^", "+", "\n", "\r", "-", "_",
        "h", "\b", "\x7F", "j", "k", "l", " "
      ].freeze
      VIBE_PAIR_TEXT_OBJECTS = {
        "(" => ["(", ")"], ")" => ["(", ")"], "b" => ["(", ")"],
        "[" => ["[", "]"], "]" => ["[", "]"],
        "{" => ["{", "}"], "}" => ["{", "}"], "B" => ["{", "}"],
        "\"" => ["\"", "\""], "'" => ["'", "'"]
      }.freeze
      VIBE_RUBY_BLOCK_OPENERS = %w[if unless case while until for def module class do begin].freeze
      VIBE_RUBY_PATHS = %w[Gemfile Rakefile Guardfile Capfile Vagrantfile].freeze
      VIBE_RUBY_EXTENSIONS = %w[.rb .rake .gemspec].freeze

      VibeOperatorTarget = Struct.new(:type, :start_index, :end_index, :replacement_text, :replacement_cursor_offset, keyword_init: true) do
        def characterwise?
          type == :characterwise
        end

        def change_replacement_text
          replacement_text.to_s
        end

        def change_cursor_index
          start_index + replacement_cursor_offset.to_i
        end
      end

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
        if ctrl_modifier?(modifier) && code == 13 && %w[insert replace].include?(@editor_state.vibe_mode)
          return vibe_record_undo { editor_insert_endwise_modifier_newline }
        end

        if @editor_state.vibe_mode == "normal" && ctrl_modifier?(modifier)
          ctrl_result = handle_vibe_normal_ctrl_key(normalized_code)
          return ctrl_result unless ctrl_result == false
        end

        logical_key = vibe_csi_u_logical_key(sequence)
        if logical_key
          return handle_vibe_search_key(logical_key) if editor_search_active?
          return handle_vibe_command_key(logical_key) if @editor_state.vibe_mode == "command"
          return handle_vibe_insert_key(logical_key) if @editor_state.vibe_mode == "insert"
          return handle_vibe_replace_key(logical_key) if @editor_state.vibe_mode == "replace"
          return handle_vibe_visual_key(logical_key) if vibe_visual_mode?
          return handle_vibe_normal_key(logical_key) if @editor_state.vibe_mode == "normal"
        end
        return false unless code == 27 || (ctrl_modifier?(modifier) && normalized_code == 99)

        return editor_search_cancel if editor_search_active?

        @editor_state.vibe_command = ""
        @editor_state.vibe_pending = ""
        @editor_state.clear_selection
        vibe_return_to_normal
      end

      def handle_vibe_normal_ctrl_key(normalized_code)
        case normalized_code
        when 104
          @editor_state.move_line_first_non_blank
        when 106
          @editor_state.move_indentation_down
        when 107
          @editor_state.move_indentation_up
        when 108
          @editor_state.move_line_end
        else
          false
        end
      end

      def vibe_csi_u_logical_key(sequence)
        code = sequence[:code]
        text = csi_u_text(sequence)
        normalized_code = code.to_i.chr.downcase.ord rescue code
        return "\n" if code == 13
        return "\x7F" if [8, 127].include?(code)
        return (normalized_code - 96).chr if ctrl_modifier?(sequence[:modifier]) && normalized_code.between?(97, 122)
        return text if text.length == 1 && printable_key?(text)
        return code.chr(Encoding::UTF_8) if sequence[:modifier] == 1 && code.between?(32, 126)

        nil
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
          readline_result = handle_vibe_insert_readline_key(key)
          return readline_result unless readline_result == false || readline_result.nil?

          key_name = key_name_for(key)
          named_result = handle_vibe_insert_named_key(key_name) if key_name
          return named_result unless named_result == false || named_result.nil?

          vibe_record_undo { editor_insert_printable(key) } if printable_key?(key)
        end
      end

      def handle_vibe_insert_readline_key(key)
        csi_result = handle_vibe_insert_readline_csi_u_key(key)
        return csi_result unless csi_result == false

        handle_vibe_insert_readline_ansi_key(key)
      end

      def handle_vibe_insert_readline_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        modifier = sequence[:modifier]
        normalized_code = sequence[:code].to_i.chr.downcase.ord rescue sequence[:code]
        if ctrl_modifier?(modifier)
          return handle_vibe_insert_readline_ctrl_key(normalized_code)
        elsif alt_modifier?(modifier)
          return handle_vibe_insert_readline_alt_key(normalized_code)
        end

        false
      end

      def handle_vibe_insert_readline_ansi_key(key)
        case key
        when "\x01"
          @editor_state.move_line_start
        when "\x02"
          @editor_state.move_left
        when "\x04"
          vibe_record_undo { @editor_state.delete_at_cursor }
        when "\x05"
          @editor_state.move_line_end
        when "\x06"
          @editor_state.move_right
        when "\x0B"
          vibe_record_undo { @editor_state.kill_line_after_cursor }
        when "\x15"
          vibe_record_undo { @editor_state.kill_line_before_cursor }
        when "\x17"
          vibe_record_undo { @editor_state.delete_word_before_cursor }
        when "\x19"
          vibe_record_undo { @editor_state.yank_kill_buffer }
        when "\e[D", "\eOD"
          @editor_state.move_left
        when "\e[C", "\eOC"
          @editor_state.move_right
        when "\e[H", "\eOH", "\e[1~", "\e[7~"
          @editor_state.move_line_start
        when "\e[F", "\eOF", "\e[4~", "\e[8~"
          @editor_state.move_line_end
        when "\e[3~"
          vibe_record_undo { @editor_state.delete_at_cursor }
        when "\eb", "\eB"
          @editor_state.move_to_previous_word
        when "\ef", "\eF"
          @editor_state.move_to_next_word
        when "\ed", "\eD"
          vibe_record_undo { @editor_state.delete_word_after_cursor }
        when "\e\b", "\e\x7F"
          vibe_record_undo { @editor_state.delete_word_before_cursor }
        else
          handle_vibe_insert_modified_ansi_key(key)
        end
      end

      def handle_vibe_insert_readline_ctrl_key(normalized_code)
        case normalized_code
        when 97
          @editor_state.move_line_start
        when 98
          @editor_state.move_left
        when 100
          vibe_record_undo { @editor_state.delete_at_cursor }
        when 101
          @editor_state.move_line_end
        when 102
          @editor_state.move_right
        when 107
          vibe_record_undo { @editor_state.kill_line_after_cursor }
        when 117
          vibe_record_undo { @editor_state.kill_line_before_cursor }
        when 119
          vibe_record_undo { @editor_state.delete_word_before_cursor }
        when 121
          vibe_record_undo { @editor_state.yank_kill_buffer }
        else
          false
        end
      end

      def handle_vibe_insert_readline_alt_key(normalized_code)
        case normalized_code
        when 98
          @editor_state.move_to_previous_word
        when 100
          vibe_record_undo { @editor_state.delete_word_after_cursor }
        when 102
          @editor_state.move_to_next_word
        else
          false
        end
      end

      def handle_vibe_insert_modified_ansi_key(key)
        sequence = parse_modified_ansi_key(key)
        return false unless sequence

        case sequence[:type]
        when :cursor
          return false unless alt_modifier?(sequence[:modifier])

          case sequence[:final]
          when "C"
            @editor_state.move_to_next_word
          when "D"
            @editor_state.move_to_previous_word
          when "F"
            @editor_state.move_line_end
          when "H"
            @editor_state.move_line_start
          else
            false
          end
        when :delete
          return false unless alt_modifier?(sequence[:modifier])

          vibe_record_undo { @editor_state.delete_word_after_cursor }
        else
          false
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
          editor_move_up
        when :down
          editor_move_down
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
          editor_move_up
        when :down
          editor_move_down
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
        return true if command.match?(/\A\d*z\z/)
        return true if command.match?(/\A\d*[cdy]\d*\z/)
        return true if command.match?(/\A\d*[cdy]\d*[ai]\z/)
        return true if command.match?(/\A\d*r\z/)

        false
      end

      def execute_vibe_normal_command(command)
        count, body = vibe_count_and_body(command)
        count = 1 if count.zero?
        case body
        when *VIBE_SIMPLE_MOTION_KEYS
          vibe_apply_cursor_motion(body, count)
        when "gg"
          @editor_state.move_file_start
        when "G"
          line = command.match?(/\A\d+G\z/) ? count - 1 : @editor_state.lines.length - 1
          @editor_state.set_cursor_line_and_column(line, 0)
        when "zz"
          vibe_position_cursor_line(:center)
        when "zt"
          vibe_position_cursor_line(:top)
        when "zb"
          vibe_position_cursor_line(:bottom)
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
        when "%"
          vibe_jump_to_matching_pair
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
          elsif body.start_with?("z") && body.length > 1
            execute_vibe_normal_command(body[1..])
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
          editor_move_up
        when :down
          editor_move_down
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
        vibe_apply_cursor_motion(body, count)
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
        return [0, "0"] if command == "0"

        match = command.match(/\A(\d*)(.*)\z/)
        [match[1].to_i, match[2]]
      end

      def vibe_move_to_relative_line_first_non_blank(offset)
        line, = @editor_state.cursor_line_and_column
        @editor_state.move_to_line_first_non_blank(line + offset)
      end

      def vibe_move_to_screen_line(offset)
        target_row = @editor_state.viewport_row + offset
        if current_editor_soft_wrap?
          visual_rows = editor_visual_rows(current_editor_text_width)
          line_index = visual_rows[target_row]&.fetch(:line_index) || @editor_state.lines.length - 1
          @editor_state.move_to_line_first_non_blank(line_index)
        else
          @editor_state.move_to_line_first_non_blank(target_row)
        end
      end

      def vibe_position_cursor_line(position)
        row = if current_editor_soft_wrap?
                editor_visual_row_for(*@editor_state.cursor_line_and_column, current_editor_text_width)
              else
                @editor_state.cursor_line_and_column.first
              end
        offset = case position
                 when :top then 0
                 when :bottom then editor_page_rows - 1
                 else editor_page_rows / 2
                 end
        @editor_state.viewport_row = [[row - offset, 0].max, vibe_last_viewport_row].min
      end

      def vibe_last_viewport_row
        visible_count = editor_page_rows
        if current_editor_soft_wrap?
          [editor_visual_rows(current_editor_text_width).length - visible_count, 0].max
        else
          [@editor_state.lines.length - visible_count, 0].max
        end
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

        target = vibe_operator_target(motion, count)
        return false unless target
        return @editor_state.status = "Empty range" if target.start_index == target.end_index

        vibe_apply_operator_to_target(operator, target, command, motion, count, motion_count)
      end

      def vibe_apply_operator_to_target(operator, target, command, motion, count, motion_count)
        case operator
        when "d"
          @editor_state.copy_range(target.start_index, target.end_index)
          vibe_record_undo { @editor_state.replace_range(target.start_index, target.end_index, "") }
          @editor_state.status = "Deleted"
          vibe_remember_change(command)
        when "c"
          @editor_state.copy_range(target.start_index, target.end_index)
          vibe_record_undo do
            @editor_state.replace_range(target.start_index, target.end_index, target.change_replacement_text)
            @editor_state.cursor = target.change_cursor_index
          end
          vibe_enter_insert_mode(vibe_build_change_command(operator, motion, count, motion_count))
        else
          vibe_copy_range(target.start_index, target.end_index, "Yanked")
          @editor_state.cursor = target.start_index
        end
      end

      def vibe_operator_target(motion, count)
        return vibe_text_object_target(motion) if motion.match?(/\A[ai].\z/)
        return vibe_word_motion_target(motion, count) if %w[w e b].include?(motion)

        start_index = @editor_state.cursor
        return false unless vibe_apply_motion(motion, count)

        end_index = @editor_state.cursor
        VibeOperatorTarget.new(type: :characterwise, start_index: start_index, end_index: end_index)
      end

      def vibe_word_motion_target(motion, count)
        start_index = @editor_state.cursor
        end_index = start_index
        if motion == "w"
          end_index = vibe_word_operator_forward_index(end_index, count)
        else
          count.times { end_index = vibe_word_motion_index(motion, end_index) }
          end_index = [end_index + 1, @editor_state.buffer.length].min if motion == "e"
        end
        @editor_state.cursor = end_index
        VibeOperatorTarget.new(type: :characterwise, start_index: start_index, end_index: end_index)
      end

      def vibe_word_operator_forward_index(index, count)
        cursor = index
        buffer = @editor_state.buffer
        count.times do |step|
          current_kind = vibe_word_kind(buffer[cursor])
          cursor += 1 while cursor < buffer.length && vibe_word_kind(buffer[cursor]) == current_kind
          if step < count - 1
            cursor += 1 while cursor < buffer.length && vibe_word_kind(buffer[cursor]) == :space
          end
        end
        cursor
      end

      def vibe_word_motion_index(motion, index)
        original_cursor = @editor_state.cursor
        @editor_state.cursor = index
        case motion
        when "w"
          vibe_move_to_next_word_start
        when "e"
          vibe_move_to_word_end
        else
          vibe_move_to_previous_word_start
        end
        @editor_state.cursor
      ensure
        @editor_state.cursor = original_cursor
      end

      def vibe_text_object_target(text_object)
        case text_object
        when "iw"
          vibe_inner_word_target
        when "aw"
          vibe_a_word_target
        when "ir", "ar"
          vibe_ruby_block_target(text_object)
        when "ip", "ap"
          vibe_paragraph_target(text_object)
        else
          return vibe_pair_text_object_target(text_object) if VIBE_PAIR_TEXT_OBJECTS.key?(text_object[1])

          @editor_state.status = "Unsupported text object: #{text_object}"
          false
        end
      end

      def vibe_paragraph_target(text_object)
        line, = @editor_state.cursor_line_and_column
        lines = @editor_state.lines
        if lines[line].to_s.strip.empty?
          @editor_state.status = "Paragraph not found"
          return false
        end

        start_line = line
        start_line -= 1 while start_line.positive? && !lines[start_line - 1].to_s.strip.empty?
        end_line = line
        end_line += 1 while end_line < lines.length - 1 && !lines[end_line + 1].to_s.strip.empty?

        if text_object == "ap"
          if end_line < lines.length - 1 && lines[end_line + 1].to_s.strip.empty?
            end_line += 1 while end_line < lines.length - 1 && lines[end_line + 1].to_s.strip.empty?
          else
            start_line -= 1 while start_line.positive? && lines[start_line - 1].to_s.strip.empty?
          end
        end

        VibeOperatorTarget.new(
          type: :characterwise,
          start_index: @editor_state.line_range(start_line)[0],
          end_index: @editor_state.line_range(end_line)[1]
        )
      end

      def vibe_ruby_block_target(text_object)
        unless vibe_ruby_file?
          @editor_state.status = "Ruby text object requires Ruby file"
          return false
        end

        block = vibe_enclosing_ruby_block
        unless block
          @editor_state.status = "Ruby block not found"
          return false
        end

        start_line = block[:start_line]
        end_line = block[:end_line]
        if text_object.start_with?("i")
          start_line += 1
          end_line -= 1
        end
        if start_line > end_line
          @editor_state.status = "Empty Ruby block"
          return false
        end

        replacement_text = nil
        replacement_cursor_offset = nil
        if text_object == "ir"
          indentation = @editor_state.lines[start_line].to_s[/\A\s*/].to_s
          replacement_text = "#{indentation}\n"
          replacement_cursor_offset = indentation.length
        end

        VibeOperatorTarget.new(
          type: :characterwise,
          start_index: @editor_state.line_range(start_line)[0],
          end_index: @editor_state.line_range(end_line)[1],
          replacement_text: replacement_text,
          replacement_cursor_offset: replacement_cursor_offset
        )
      end

      def vibe_ruby_file?
        path = File.basename(@editor_state.path.to_s)
        VIBE_RUBY_PATHS.include?(path) || VIBE_RUBY_EXTENSIONS.include?(File.extname(path))
      end

      def vibe_enclosing_ruby_block
        blocks = []
        stack = []
        @editor_state.lines.each_with_index do |line, line_index|
          tokens = vibe_ruby_block_tokens(line)
          tokens.each do |token|
            if token == "end"
              opener = stack.pop
              blocks << opener.merge(end_line: line_index) if opener
            elsif VIBE_RUBY_BLOCK_OPENERS.include?(token)
              stack << { opener: token, start_line: line_index }
            end
          end
        end

        cursor_line, = @editor_state.cursor_line_and_column
        blocks.select { |block| block[:start_line] <= cursor_line && cursor_line <= block[:end_line] }
              .max_by { |block| block[:start_line] }
      end

      def vibe_ruby_block_tokens(line)
        code = vibe_ruby_code_for_block_scan(line)
        tokens = []
        stripped = code.strip
        opener = stripped.match(/\A(if|unless|case|while|until|for|def|module|class|begin)\b/)
        tokens << opener[1] if opener
        tokens << "do" if stripped.match?(/\bdo\b/)
        tokens << "end" if stripped.match?(/\Aend\b/)
        tokens
      end

      def vibe_ruby_code_for_block_scan(line)
        code = +""
        quote = nil
        escaped = false
        line.each_char do |char|
          if quote
            escaped = !escaped && char == "\\"
            quote = nil if char == quote && !escaped
            next
          end

          break if char == "#"
          if ["'", '"'].include?(char)
            quote = char
            escaped = false
            next
          end
          code << char
        end
        code
      end

      def vibe_pair_text_object_target(text_object)
        include_pair = text_object.start_with?("a")
        pair = VIBE_PAIR_TEXT_OBJECTS[text_object[1]]
        range = pair[0] == pair[1] ? vibe_quote_pair_range(pair[0]) : vibe_delimited_pair_range(pair[0], pair[1])
        return @editor_state.status = "No #{pair.join} pair around cursor" unless range

        start_index, end_index = range
        start_index += 1 unless include_pair
        VibeOperatorTarget.new(
          type: :characterwise,
          start_index: start_index,
          end_index: include_pair ? end_index + 1 : end_index
        )
      end

      def vibe_jump_to_matching_pair
        pairs = VIBE_PAIR_TEXT_OBJECTS.values.uniq.reject { |open_char, close_char| open_char == close_char }
        pairs.each do |open_char, close_char|
          cursor = @editor_state.cursor
          if @editor_state.buffer[cursor] == open_char
            return @editor_state.cursor = vibe_find_forward_pair(cursor, open_char, close_char)
          elsif @editor_state.buffer[cursor] == close_char
            return @editor_state.cursor = vibe_find_backward_pair(cursor, open_char, close_char)
          end
        end
        @editor_state.status = "No matching pair under cursor"
        false
      end

      def vibe_find_forward_pair(open_index, open_char, close_char)
        depth = 0
        (open_index + 1...@editor_state.buffer.length).each do |index|
          char = @editor_state.buffer[index]
          depth += 1 if char == open_char
          if char == close_char
            return index if depth.zero?

            depth -= 1
          end
        end
        open_index
      end

      def vibe_find_backward_pair(close_index, open_char, close_char)
        depth = 0
        (close_index - 1).downto(0) do |index|
          char = @editor_state.buffer[index]
          depth += 1 if char == close_char
          if char == open_char
            return index if depth.zero?

            depth -= 1
          end
        end
        close_index
      end

      def vibe_delimited_pair_range(open_char, close_char)
        buffer = @editor_state.buffer
        cursor = @editor_state.cursor
        depth = 0
        open_index = nil
        cursor.downto(0) do |index|
          char = buffer[index]
          depth += 1 if char == close_char
          if char == open_char
            if depth.zero?
              open_index = index
              break
            end
            depth -= 1
          end
        end
        return nil unless open_index

        depth = 0
        close_index = nil
        (open_index + 1...buffer.length).each do |index|
          char = buffer[index]
          depth += 1 if char == open_char
          if char == close_char
            if depth.zero?
              close_index = index
              break
            end
            depth -= 1
          end
        end
        close_index ? [open_index, close_index] : nil
      end

      def vibe_quote_pair_range(quote)
        buffer = @editor_state.buffer
        cursor = @editor_state.cursor
        open_index = buffer.rindex(quote, cursor)
        return nil unless open_index

        close_index = buffer.index(quote, open_index + 1)
        close_index ? [open_index, close_index] : nil
      end

      def vibe_inner_word_target
        range = vibe_word_range_at(@editor_state.cursor)
        return @editor_state.status = "No word under cursor" unless range

        VibeOperatorTarget.new(type: :characterwise, start_index: range[0], end_index: range[1])
      end

      def vibe_a_word_target
        range = vibe_word_range_at(@editor_state.cursor)
        return @editor_state.status = "No word under cursor" unless range

        start_index, end_index = range
        if end_index < @editor_state.buffer.length && vibe_word_kind(@editor_state.buffer[end_index]) == :space
          end_index += 1 while end_index < @editor_state.buffer.length && vibe_word_kind(@editor_state.buffer[end_index]) == :space
        else
          start_index -= 1 while start_index.positive? && vibe_word_kind(@editor_state.buffer[start_index - 1]) == :space
        end
        VibeOperatorTarget.new(type: :characterwise, start_index: start_index, end_index: end_index)
      end

      def vibe_word_range_at(offset)
        buffer = @editor_state.buffer
        return nil if buffer.empty?

        index = [[offset.to_i, 0].max, buffer.length - 1].min
        kind = vibe_word_kind(buffer[index])
        return nil if kind == :space

        start_index = index
        start_index -= 1 while start_index.positive? && vibe_word_kind(buffer[start_index - 1]) == kind
        end_index = index + 1
        end_index += 1 while end_index < buffer.length && vibe_word_kind(buffer[end_index]) == kind
        [start_index, end_index]
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

      def vibe_apply_cursor_motion(motion, count)
        case motion
        when "w"
          count.times { vibe_move_to_next_word_start }
        when "e"
          count.times { vibe_move_to_word_end }
        when "b"
          count.times { vibe_move_to_previous_word_start }
        else
          return vibe_apply_motion(motion, count)
        end
        true
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
          count.times { editor_move_down }
        when "k"
          count.times { editor_move_up }
        when "l", " "
          count.times { @editor_state.move_right }
        else
          @editor_state.status = "Unsupported motion: #{motion}"
          return false
        end
        true
      end

      def vibe_move_to_next_word_start
        cursor = @editor_state.cursor
        buffer = @editor_state.buffer
        return if cursor >= buffer.length

        current_kind = vibe_word_kind(buffer[cursor])
        cursor += 1 while cursor < buffer.length && vibe_word_kind(buffer[cursor]) == current_kind
        cursor += 1 while cursor < buffer.length && vibe_word_kind(buffer[cursor]) == :space
        @editor_state.cursor = cursor
      end

      def vibe_move_to_word_end
        cursor = @editor_state.cursor
        buffer = @editor_state.buffer
        return if buffer.empty? || cursor >= buffer.length

        current_kind = vibe_word_kind(buffer[cursor])
        next_kind = cursor < buffer.length - 1 ? vibe_word_kind(buffer[cursor + 1]) : nil
        cursor += 1 if current_kind != :space && next_kind && next_kind != current_kind
        cursor += 1 while cursor < buffer.length && vibe_word_kind(buffer[cursor]) == :space
        return @editor_state.cursor = cursor if cursor >= buffer.length

        current_kind = vibe_word_kind(buffer[cursor])
        cursor += 1 while cursor < buffer.length - 1 && vibe_word_kind(buffer[cursor + 1]) == current_kind
        @editor_state.cursor = cursor
      end

      def vibe_move_to_previous_word_start
        cursor = @editor_state.cursor
        buffer = @editor_state.buffer
        return if cursor.zero? || buffer.empty?

        cursor -= 1
        cursor -= 1 while cursor.positive? && vibe_word_kind(buffer[cursor]) == :space
        current_kind = vibe_word_kind(buffer[cursor])
        cursor -= 1 while cursor.positive? && vibe_word_kind(buffer[cursor - 1]) == current_kind
        @editor_state.cursor = cursor
      end

      def vibe_word_kind(char)
        case char.to_s
        when /\s/
          :space
        when /[[:alnum:]_]/
          :keyword
        else
          :punctuation
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
