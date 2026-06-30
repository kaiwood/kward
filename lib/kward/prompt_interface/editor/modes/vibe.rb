# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Vibe-style keymap for the built-in composer file editor.
    module VibeEditorMode
      VIBE_SIMPLE_MOTION_KEYS = [
        "w", "e", "b", "$", "0", "^", "+", "\n", "\r", "-", "_",
        "h", "\b", "\x7F", "j", "k", "l", " ", "{", "}"
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

        return handle_vibe_command_key(key) if @editor_state.vibe_mode == "command"

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        return vibe_stop_macro_recording if key == "q" && @editor_state.vibe_recording_macro && !%w[insert replace command].include?(@editor_state.vibe_mode)
        vibe_record_macro_key(key)
        return vibe_begin_visual_mode("visual_block") if key == TerminalKeys::CTRL_V && @editor_state.vibe_mode == "normal"
        return handle_vibe_repeat_change if key == "." && @editor_state.vibe_mode == "normal"
        return handle_vibe_search_key(key) if editor_search_active?
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
        return handle_vibe_key(logical_key) if logical_key
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
        when 118
          vibe_begin_visual_mode("visual_block")
        else
          false
        end
      end

      def vibe_csi_u_logical_key(sequence)
        code = sequence[:code]
        text = csi_u_text(sequence)
        normalized_code = code.to_i.chr.downcase.ord rescue code
        return "\t" if code == 9
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
        when "\e", TerminalKeys::CTRL_C
          editor_search_cancel
        else
          editor_search_append(key) if printable_key?(key)
        end
        true
      end

      def handle_vibe_insert_key(key)
        return if handle_editor_bracketed_paste_key(key)

        vibe_record_insert_change_key(key)
        tab_result = handle_editor_tab_key(key) { |direction| vibe_record_undo { direction == :forward ? editor_insert_tab : editor_outdent_tab } }
        return tab_result unless tab_result == false

        case key
        when "\e", TerminalKeys::CTRL_C, :escape
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

      def handle_vibe_replace_key(key)
        return if handle_editor_bracketed_paste_key(key)

        vibe_record_insert_change_key(key)
        tab_result = handle_editor_tab_key(key) { |direction| vibe_record_undo { direction == :forward ? editor_insert_tab : editor_outdent_tab } }
        return tab_result unless tab_result == false

        case key
        when "\e", TerminalKeys::CTRL_C, :escape
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
        when "\e", TerminalKeys::CTRL_C, :escape
          @editor_state.vibe_command = ""
          vibe_return_to_normal
        when "\b", "\x7F"
          @editor_state.vibe_command = @editor_state.vibe_command[0...-1].to_s
          @editor_state.status = ":#{@editor_state.vibe_command}"
        when "\t"
          vibe_complete_command_path
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
        when /\Aw\s+(.+)\z/
          save_editor(Regexp.last_match(1))
        when /\Ae(!?)\s+(.+)\z/
          vibe_edit_file(Regexp.last_match(2), force: Regexp.last_match(1) == "!")
        when "run"
          vibe_record_undo { run_editor_buffer }
        when "q"
          vibe_quit_editor
        when "q!"
          close_editor
        when "wq"
          save_editor && close_editor
        when /\Awq\s+(.+)\z/
          save_editor(Regexp.last_match(1)) && close_editor
        when "x"
          save_editor if @editor_state&.dirty?
          close_editor if @editor_state
        when /\A(?:(%|\d+,\d+))?s\/([^\/]*)\/([^\/]*)\/(g?)\z/
          vibe_substitute_command(Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3), global: Regexp.last_match(4) == "g")
        when /\A\d+\z/
          @editor_state.set_cursor_line_and_column(command.to_i - 1, 0)
          @editor_state.status = "Line #{command}"
        else
          @editor_state.status = "Unknown command: #{command}"
        end
        true
      end

      def vibe_edit_file(path, force: false)
        if @editor_state.dirty? && !force
          @editor_state.status = "No write since last change (:e! overrides)"
          return true
        end

        open_editor(path, allow_new: true)
      end

      def vibe_complete_command_path
        command = @editor_state.vibe_command.to_s
        match = command.match(/\A(e!?)\s+(.*)\z/)
        return false unless match

        prefix = match[2]
        candidates = vibe_path_completion_candidates(prefix)
        if candidates.empty?
          @editor_state.status = "No matches"
          return true
        end

        replacement = candidates.length == 1 ? candidates.first : vibe_common_prefix(candidates)
        if replacement.length > prefix.length
          @editor_state.vibe_command = "#{match[1]} #{replacement}"
          @editor_state.status = ":#{@editor_state.vibe_command}"
        elsif candidates.length > 1
          @editor_state.status = vibe_path_completion_status(candidates)
        end
        true
      end

      def vibe_path_completion_candidates(prefix)
        directory_prefix, basename_prefix = vibe_split_path_completion_prefix(prefix)
        search_directory = File.expand_path(directory_prefix.empty? ? "." : directory_prefix, Dir.pwd)
        root = File.expand_path(Dir.pwd)
        return [] unless search_directory == root || search_directory.start_with?("#{root}/")
        return [] unless File.directory?(search_directory)

        Dir.children(search_directory).sort.filter_map do |entry|
          next if entry.start_with?(".") && !basename_prefix.start_with?(".")
          next unless entry.start_with?(basename_prefix)

          path = File.join(search_directory, entry)
          candidate = "#{directory_prefix}#{entry}"
          File.directory?(path) ? "#{candidate}/" : candidate
        end
      rescue StandardError
        []
      end

      def vibe_split_path_completion_prefix(prefix)
        if prefix.include?(File::SEPARATOR)
          directory = prefix[0..prefix.rindex(File::SEPARATOR)].to_s
          basename = prefix[(prefix.rindex(File::SEPARATOR) + 1)..].to_s
          [directory, basename]
        else
          ["", prefix]
        end
      end

      def vibe_common_prefix(values)
        return "" if values.empty?

        values.reduce(values.first.dup) do |prefix, value|
          prefix = prefix[0...-1] until value.start_with?(prefix) || prefix.empty?
          prefix
        end
      end

      def vibe_path_completion_status(candidates)
        visible = candidates.first(6)
        suffix = candidates.length > visible.length ? " …" : ""
        "#{candidates.length} matches: #{visible.join("  ")}#{suffix}"
      end

      def vibe_substitute_command(range, pattern, replacement, global: false)
        if pattern.empty?
          @editor_state.status = "Substitute pattern required"
          return false
        end

        start_line = 0
        end_line = @editor_state.lines.length - 1
        if range&.include?(",")
          start_line, end_line = range.split(",", 2).map { |value| value.to_i - 1 }
        end
        start_line = [[start_line, 0].max, @editor_state.lines.length - 1].min
        end_line = [[end_line, 0].max, @editor_state.lines.length - 1].min
        start_line, end_line = [start_line, end_line].minmax
        start_index = @editor_state.line_range(start_line)[0]
        end_index = @editor_state.line_range(end_line)[1]
        text = @editor_state.buffer[start_index...end_index].to_s
        changed = global ? text.gsub(pattern, replacement) : text.lines.map { |line| line.sub(pattern, replacement) }.join
        vibe_record_undo { @editor_state.replace_range(start_index, end_index, changed) }
        @editor_state.status = "Substituted"
        true
      end

      def vibe_quit_editor
        return close_editor unless @editor_state.dirty?

        @editor_state.status = "No write since last change (:q! overrides)"
        true
      end

      def handle_vibe_normal_key(key)
        if key == "\e" || key == TerminalKeys::CTRL_C
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
        return vibe_store_pending_command(pending) if vibe_waiting_for_more?(pending)

        @editor_state.vibe_pending = ""
        execute_vibe_normal_command(pending)
        true
      end

      def vibe_store_pending_command(command)
        @editor_state.vibe_pending = command
        @editor_state.status = "#{@editor_state.vibe_mode.upcase.tr("_", " ")} #{command}"
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
        ["\n", "\r", "\b", "\x7F", TerminalKeys::CTRL_B, TerminalKeys::CTRL_D, TerminalKeys::CTRL_E, TerminalKeys::CTRL_F, TerminalKeys::CTRL_R, TerminalKeys::CTRL_U, TerminalKeys::CTRL_Y].include?(key)
      end

      def vibe_visual_mode?
        %w[visual visual_line visual_block].include?(@editor_state.vibe_mode)
      end

      def vibe_return_to_normal
        vibe_apply_visual_block_insert if @editor_state.vibe_visual_block_insert
        @editor_state.vibe_mode = "normal"
        @editor_state.status = "NORMAL · i insert · :w save · :q quit"
        true
      end

      def vibe_cancel_visual_mode
        @editor_state.vibe_pending = ""
        vibe_remember_visual_selection
        @editor_state.clear_selection
        vibe_return_to_normal
      end

      def vibe_remember_visual_selection
        return unless @editor_state.selection_active?

        @editor_state.vibe_last_visual_selection = {
          mode: @editor_state.vibe_mode,
          anchor: @editor_state.selection_anchor,
          cursor: @editor_state.cursor
        }
      end

      def vibe_waiting_for_more?(command)
        return true if command.match?(/\A\d+\z/) && command != "0"
        return true if command.match?(/\A\d*g\z/)
        return true if command.match?(/\A\d*z\z/)
        return true if command.match?(/\A\d*[cdy]\d*\z/)
        return true if command.match?(/\A\d*[cdy]\d*[ai]\z/)
        return true if command.match?(/\A\d*[cdy]\d*[fFtT]\z/)
        return true if command.match?(/\A\d*[fFtT]\z/)
        return true if command.match?(/\A\d*r\z/)
        return true if command.match?(/\Am\z/)
        return true if command.match?(/\A"[a-z]?\z/)
        return true if command.match?(/\A"[a-z][cdy]\z/)
        return true if command.match?(/\A"[a-z][cdy][ai]\z/)
        return true if command.match?(/\Aq\z/)
        return true if command.match?(/\A@\z/)
        return true if command.match?(/\A[\[\]]\z/)
        return true if command.match?(/\A['`]\z/)

        false
      end

      def execute_vibe_normal_command(command)
        original_command = command
        register = nil
        if (register_match = command.match(/\A"([a-z])(.*)\z/))
          register = register_match[1]
          command = register_match[2]
        end
        @vibe_active_register = register
        count, body = vibe_count_and_body(command)
        count = 1 if count.zero?
        case body
        when *VIBE_SIMPLE_MOTION_KEYS
          vibe_apply_cursor_motion(body, count)
        when "gg"
          @editor_state.move_file_start
        when "gv"
          vibe_restore_visual_selection
        when "]m"
          vibe_jump_ruby_method(:forward)
        when "[m"
          vibe_jump_ruby_method(:backward)
        when /\Aq(.+)\z/
          vibe_start_macro_recording(Regexp.last_match(1))
        when "@@"
          vibe_play_macro(@editor_state.vibe_last_macro)
        when /\A@(.+)\z/
          vibe_play_macro(Regexp.last_match(1))
        when /\Am(.+)\z/
          vibe_set_mark(Regexp.last_match(1))
        when /\A'(.+)\z/
          vibe_jump_to_mark(Regexp.last_match(1), linewise: true)
        when /\A`(.+)\z/
          vibe_jump_to_mark(Regexp.last_match(1), linewise: false)
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
        when TerminalKeys::CTRL_F
          @editor_state.page_down(editor_page_rows)
        when TerminalKeys::CTRL_B
          @editor_state.page_up(editor_page_rows)
        when TerminalKeys::CTRL_D
          @editor_state.page_down(vibe_half_page_rows)
        when TerminalKeys::CTRL_U
          @editor_state.page_up(vibe_half_page_rows)
        when TerminalKeys::CTRL_E
          vibe_scroll_down
        when TerminalKeys::CTRL_Y
          vibe_scroll_up
        when TerminalKeys::CTRL_R
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
        when /^([fFtT])(.?)$/
          vibe_find_character(Regexp.last_match(1), Regexp.last_match(2), count)
        when ";"
          vibe_repeat_find_character
        when ","
          vibe_repeat_find_character(reverse: true)
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
          vibe_store_active_register
          vibe_remember_change(command)
        when "cc"
          vibe_change_lines(count, command)
          vibe_store_active_register
        when "yy"
          vibe_yank_lines(count)
          vibe_store_active_register
        when "p"
          vibe_record_undo { @editor_state.insert(vibe_active_register_text) }
          vibe_remember_change(original_command)
        when "P"
          vibe_paste_before(original_command)
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
      ensure
        @vibe_active_register = nil
      end

      def handle_vibe_visual_key(key)
        key_name = key_name_for(key)
        return handle_vibe_visual_named_key(key_name) if key_name
        if key == "\e" || key == TerminalKeys::CTRL_C
          @editor_state.vibe_pending = ""
          vibe_cancel_visual_mode
          return true
        end
        return true unless printable_key?(key)

        command = @editor_state.vibe_pending.to_s + key
        return vibe_store_pending_command(command) if vibe_visual_waiting_for_more?(command)

        @editor_state.vibe_pending = ""
        execute_vibe_visual_command(command)
        true
      end

      def execute_vibe_visual_command(command)
        count, body = vibe_count_and_body(command)
        count = 1 if count.zero?

        case body
        when *EditorAutoClosePairs::AUTO_CLOSE_OPENERS
          vibe_record_undo { editor_insert_printable(body) }
          vibe_return_to_normal
        when "y"
          vibe_yank_visual_selection
        when "d", "x"
          vibe_delete_visual_selection
        when "c"
          vibe_change_visual_selection
        when "p"
          vibe_paste_visual_selection
        when "I"
          vibe_begin_visual_block_insert(:before)
        when "A"
          vibe_begin_visual_block_insert(:after)
        when ">"
          vibe_indent_visual_selection(:right)
        when "<"
          vibe_indent_visual_selection(:left)
        when "J"
          vibe_join_visual_selection
        when "~"
          vibe_transform_visual_selection(:swapcase)
        when "u"
          vibe_transform_visual_selection(:downcase)
        when "U"
          vibe_transform_visual_selection(:upcase)
        when "/"
          editor_search_begin
        when "?"
          editor_search_begin(:backward)
        when "n"
          editor_search_repeat
        when "N"
          editor_search_repeat(vibe_opposite_search_direction)
        when "o"
          vibe_switch_visual_selection_end
        when "G"
          vibe_visual_goto_line(command.match?(/\A\d+G\z/) ? count : nil)
        when "gg"
          vibe_visual_goto_line(command.match?(/\A\d+gg\z/) ? count : 1)
        when "%"
          vibe_jump_to_matching_pair
        when /^([fFtT])(.?)$/
          vibe_find_character(Regexp.last_match(1), Regexp.last_match(2), count)
        when /\A[ai].\z/
          vibe_select_text_object(body)
        when ";"
          vibe_repeat_find_character
        when ","
          vibe_repeat_find_character(reverse: true)
        else
          vibe_move_visual_selection(body, count)
        end
      end

      def vibe_visual_waiting_for_more?(command)
        return true if command.match?(/\A[1-9]\d*\z/)
        return true if command.match?(/\A\d*g\z/)
        return true if command.match?(/\A\d*[fFtT]\z/)
        return true if command.match?(/\A\d*[ai]\z/)

        false
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

      def vibe_switch_visual_selection_end
        @editor_state.selection_anchor, @editor_state.cursor = @editor_state.cursor, @editor_state.selection_anchor
        true
      end

      def vibe_jump_ruby_method(direction)
        unless vibe_ruby_file?
          @editor_state.status = "Ruby navigation requires Ruby file"
          return false
        end

        line, = @editor_state.cursor_line_and_column
        candidates = @editor_state.lines.each_with_index.select { |source, _index| source.match?(/\A\s*def\b/) }.map(&:last)
        target = if direction == :forward
                   candidates.find { |index| index > line }
                 else
                   candidates.reverse.find { |index| index < line }
                 end
        unless target
          @editor_state.status = "Ruby method not found"
          return false
        end

        @editor_state.move_to_line_first_non_blank(target)
        true
      end

      def vibe_start_macro_recording(name)
        @editor_state.vibe_recording_macro = name
        @editor_state.vibe_macros[name] = []
        @editor_state.status = "Recording macro #{name}"
        true
      end

      def vibe_stop_macro_recording
        name = @editor_state.vibe_recording_macro
        @editor_state.vibe_pending = ""
        @editor_state.vibe_recording_macro = nil
        @editor_state.vibe_last_macro = name
        @editor_state.status = "Recorded macro #{name}"
        true
      end

      def vibe_record_macro_key(key)
        name = @editor_state.vibe_recording_macro
        return if !name || @vibe_replaying_macro

        @editor_state.vibe_macros[name] << key
      end

      def vibe_play_macro(name)
        macro = @editor_state.vibe_macros[name]
        unless macro
          @editor_state.status = "Macro not set: #{name}"
          return false
        end

        @editor_state.vibe_last_macro = name
        @vibe_replaying_macro = true
        macro.each { |key| handle_vibe_key(key) }
        @editor_state.status = "Played macro #{name}"
        true
      ensure
        @vibe_replaying_macro = false
      end

      def vibe_set_mark(name)
        @editor_state.vibe_marks[name] = { cursor: @editor_state.cursor }
        @editor_state.status = "Set mark #{name}"
        true
      end

      def vibe_jump_to_mark(name, linewise:)
        mark = @editor_state.vibe_marks[name]
        unless mark
          @editor_state.status = "Mark not set: #{name}"
          return false
        end

        @editor_state.cursor = [[mark[:cursor], 0].max, @editor_state.buffer.length].min
        @editor_state.move_line_first_non_blank if linewise
        true
      end

      def vibe_restore_visual_selection
        selection = @editor_state.vibe_last_visual_selection
        unless selection
          @editor_state.status = "No visual selection to restore"
          return false
        end

        @editor_state.vibe_mode = selection[:mode]
        @editor_state.selection_anchor = [[selection[:anchor], 0].max, @editor_state.buffer.length].min
        @editor_state.cursor = [[selection[:cursor], 0].max, @editor_state.buffer.length].min
        @editor_state.status = case @editor_state.vibe_mode
                               when "visual_line" then "VISUAL LINE"
                               when "visual_block" then "VISUAL BLOCK"
                               else "VISUAL"
                               end
        true
      end

      def vibe_begin_visual_mode(mode)
        @editor_state.clear_selection
        @editor_state.selection_anchor = @editor_state.cursor
        @editor_state.vibe_mode = mode
        @editor_state.status = case mode
                               when "visual_line" then "VISUAL LINE"
                               when "visual_block" then "VISUAL BLOCK"
                               else "VISUAL"
                               end
        true
      end

      def vibe_select_text_object(text_object)
        target = vibe_text_object_target(text_object)
        return false unless target

        @editor_state.selection_anchor = target.start_index
        @editor_state.cursor = [target.end_index - 1, target.start_index].max
        true
      end

      def vibe_visual_goto_line(line_number = nil)
        line = line_number ? line_number - 1 : @editor_state.lines.length - 1
        @editor_state.set_cursor_line_and_column(line, 0)
        true
      end

      def vibe_move_visual_selection(motion, count = 1)
        vibe_apply_cursor_motion(motion, count)
      end

      def vibe_visual_range
        @editor_state.selection_range
      end

      def vibe_yank_visual_selection
        if @editor_state.vibe_mode == "visual_block"
          @editor_state.kill_buffer = @editor_state.selected_text
          @editor_state.status = "Yanked selection"
          vibe_cancel_visual_mode
          return true
        end

        range = vibe_visual_range
        return false unless range

        vibe_copy_range(range[0], range[1], "Yanked selection")
        vibe_cancel_visual_mode
      end

      def vibe_delete_visual_selection
        if @editor_state.vibe_mode == "visual_block"
          @editor_state.kill_buffer = @editor_state.selected_text
          vibe_record_undo { @editor_state.selection_ranges.reverse_each { |range| @editor_state.replace_range(range[0], range[1], "") } }
          vibe_cancel_visual_mode
          return true
        end

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

      def vibe_begin_visual_block_insert(position)
        return vibe_move_visual_selection(position == :before ? "I" : "A") unless @editor_state.vibe_mode == "visual_block"

        anchor_line, anchor_column = @editor_state.cursor_line_and_column_for(@editor_state.selection_anchor)
        cursor_line, cursor_column = @editor_state.cursor_line_and_column
        start_line, end_line = [anchor_line, cursor_line].minmax
        start_column, end_column = [anchor_column, cursor_column].minmax
        column = position == :before ? start_column : end_column + 1
        @editor_state.vibe_visual_block_insert = { start_line: start_line, end_line: end_line, column: column }
        @editor_state.clear_selection
        @editor_state.set_cursor_line_and_column(start_line, column)
        @editor_state.vibe_visual_block_insert[:start_index] = @editor_state.cursor
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
        true
      end

      def vibe_apply_visual_block_insert
        block = @editor_state.vibe_visual_block_insert
        @editor_state.vibe_visual_block_insert = nil
        return unless block

        inserted_text = @editor_state.buffer[block[:start_index]...@editor_state.cursor].to_s
        return if inserted_text.empty?

        block[:end_line].downto(block[:start_line] + 1) do |line_index|
          line_start = @editor_state.line_start_offset(line_index)
          line_length = @editor_state.lines[line_index].to_s.length
          @editor_state.cursor = line_start + [block[:column], line_length].min
          @editor_state.insert(inserted_text)
        end
      end

      def vibe_transform_visual_selection(transform)
        range = vibe_visual_range
        return false unless range

        text = @editor_state.buffer[range[0]...range[1]].to_s
        replacement = case transform
                      when :swapcase then text.swapcase
                      when :downcase then text.downcase
                      else text.upcase
                      end
        vibe_record_undo { @editor_state.replace_range(range[0], range[1], replacement) }
        vibe_cancel_visual_mode
      end

      def vibe_join_visual_selection
        range = vibe_visual_range
        return false unless range

        start_line, = @editor_state.cursor_line_and_column_for(range[0])
        end_line, = @editor_state.cursor_line_and_column_for([range[1] - 1, range[0]].max)
        @editor_state.set_cursor_line_and_column(start_line, 0)
        vibe_join_lines(end_line - start_line + 1)
        vibe_cancel_visual_mode
      end

      def vibe_indent_visual_selection(direction)
        range = vibe_visual_range
        return false unless range

        start_line, = @editor_state.cursor_line_and_column_for(range[0])
        end_line, = @editor_state.cursor_line_and_column_for([range[1] - 1, range[0]].max)
        start_index = @editor_state.line_range(start_line)[0]
        end_index = @editor_state.line_range(end_line)[1]
        original_text = @editor_state.buffer[start_index...end_index].to_s
        lines = @editor_state.lines[start_line..end_line].map do |line|
          direction == :right ? "  #{line}" : line.sub(/\A(?:  |\t| )/, "")
        end
        replacement = lines.join("\n")
        replacement += "\n" if original_text.end_with?("\n")

        vibe_record_undo { @editor_state.replace_range(start_index, end_index, replacement) }
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
        indentation = @editor_state.lines[line].to_s[/\A\s*/].to_s
        line_end = @editor_state.line_start_offset(line) + @editor_state.lines[line].to_s.length
        vibe_record_undo do
          @editor_state.cursor = line_end
          @editor_state.insert("\n#{indentation}")
        end
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vibe_open_line_above
        line, = @editor_state.cursor_line_and_column
        indentation = @editor_state.lines[line].to_s[/\A\s*/].to_s
        start_index = @editor_state.line_start_offset(line)
        vibe_record_undo do
          @editor_state.cursor = start_index
          @editor_state.insert("#{indentation}\n")
          @editor_state.cursor = start_index + indentation.length
        end
        @editor_state.vibe_mode = "insert"
        @editor_state.status = "INSERT · Esc normal"
      end

      def vibe_paste_before(command = nil)
        text = vibe_active_register_text
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

      def vibe_active_register_text
        return @editor_state.vibe_registers[@vibe_active_register].to_s if @vibe_active_register

        @editor_state.kill_buffer.to_s
      end

      def vibe_store_active_register
        return unless @vibe_active_register

        @editor_state.vibe_registers[@vibe_active_register] = @editor_state.kill_buffer.to_s
      end

      def vibe_apply_operator_to_target(operator, target, command, motion, count, motion_count)
        case operator
        when "d"
          @editor_state.copy_range(target.start_index, target.end_index)
          vibe_record_undo { @editor_state.replace_range(target.start_index, target.end_index, "") }
          @editor_state.status = "Deleted"
          vibe_store_active_register
          vibe_remember_change(command)
        when "c"
          @editor_state.copy_range(target.start_index, target.end_index)
          vibe_record_undo do
            @editor_state.replace_range(target.start_index, target.end_index, target.change_replacement_text)
            @editor_state.cursor = target.change_cursor_index
          end
          vibe_store_active_register
          vibe_enter_insert_mode(vibe_build_change_command(operator, motion, count, motion_count))
        else
          vibe_copy_range(target.start_index, target.end_index, "Yanked")
          vibe_store_active_register
          @editor_state.cursor = target.start_index
        end
      end

      def vibe_operator_target(motion, count)
        return vibe_text_object_target(motion) if motion.match?(/\A[ai].\z/)
        return vibe_word_motion_target(motion, count) if %w[w e b].include?(motion)
        return vibe_find_motion_target(motion, count) if motion.match?(/\A[fFtT].\z/)
        return vibe_percent_motion_target if motion == "%"

        start_index = @editor_state.cursor
        return false unless vibe_apply_motion(motion, count)

        end_index = @editor_state.cursor
        VibeOperatorTarget.new(type: :characterwise, start_index: start_index, end_index: end_index)
      end

      def vibe_find_motion_target(motion, count)
        start_index = @editor_state.cursor
        command = motion[0]
        char = motion[1]
        reverse = %w[F T].include?(command)
        before = %w[t T].include?(command)
        end_index = vibe_find_character_index(char, count, reverse: reverse)
        unless end_index
          @editor_state.status = "Character not found: #{char}"
          return false
        end

        motion_index = end_index
        motion_index += reverse ? 1 : -1 if before
        @editor_state.cursor = motion_index
        target_end_index = if reverse
                             before ? end_index + 1 : end_index
                           else
                             before ? end_index : end_index + 1
                           end
        VibeOperatorTarget.new(type: :characterwise, start_index: start_index, end_index: target_end_index)
      end

      def vibe_percent_motion_target
        start_index = @editor_state.cursor
        end_index = vibe_matching_pair_index(start_index)
        unless end_index
          @editor_state.status = "No matching pair under cursor"
          return false
        end

        if end_index > start_index
          VibeOperatorTarget.new(type: :characterwise, start_index: start_index, end_index: end_index + 1)
        else
          VibeOperatorTarget.new(type: :characterwise, start_index: end_index, end_index: start_index + 1)
        end
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

      def vibe_find_character(command, char, count)
        reverse = %w[F T].include?(command)
        before = %w[t T].include?(command)
        index = vibe_find_character_index(char, count, reverse: reverse)
        unless index
          @editor_state.status = "Character not found: #{char}"
          return false
        end

        index += reverse ? 1 : -1 if before
        @editor_state.cursor = [[index, 0].max, @editor_state.buffer.length].min
        @editor_state.vibe_last_find = { command: command, char: char }
        true
      end

      def vibe_repeat_find_character(reverse: false)
        last_find = @editor_state.vibe_last_find
        return @editor_state.status = "No character find to repeat" unless last_find

        command = last_find[:command]
        command = vibe_reverse_find_command(command) if reverse
        vibe_find_character(command, last_find[:char], 1)
      end

      def vibe_reverse_find_command(command)
        { "f" => "F", "F" => "f", "t" => "T", "T" => "t" }.fetch(command)
      end

      def vibe_find_character_index(char, count, reverse: false)
        line, = @editor_state.cursor_line_and_column
        line_range = @editor_state.line_range(line)
        line_start = line_range[0]
        line_end = line_range[1]
        line_end -= 1 if line_end > line_start && @editor_state.buffer[line_end - 1] == "\n"
        cursor = @editor_state.cursor
        count.times do
          cursor = if reverse
                     @editor_state.buffer.rindex(char, cursor - 1)
                   else
                     @editor_state.buffer.index(char, cursor + 1)
                   end
          return nil unless cursor && cursor >= line_start && cursor < line_end
        end
        cursor
      end

      def vibe_jump_to_matching_pair
        index = vibe_matching_pair_index(@editor_state.cursor)
        unless index
          @editor_state.status = "No matching pair under cursor"
          return false
        end

        @editor_state.cursor = index
        true
      end

      def vibe_matching_pair_index(index)
        pairs = VIBE_PAIR_TEXT_OBJECTS.values.uniq.reject { |open_char, close_char| open_char == close_char }
        pairs.each do |open_char, close_char|
          if @editor_state.buffer[index] == open_char
            return vibe_find_forward_pair(index, open_char, close_char)
          elsif @editor_state.buffer[index] == close_char
            return vibe_find_backward_pair(index, open_char, close_char)
          end
        end
        nil
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
        quote_indexes = vibe_unescaped_quote_indexes(quote)
        cursor = @editor_state.cursor
        open_index = quote_indexes.select { |index| index <= cursor }.last
        return nil unless open_index

        close_index = quote_indexes.find { |index| index > open_index }
        close_index ? [open_index, close_index] : nil
      end

      def vibe_unescaped_quote_indexes(quote)
        indexes = []
        @editor_state.buffer.each_char.with_index do |char, index|
          indexes << index if char == quote && !vibe_escaped_character?(index)
        end
        indexes
      end

      def vibe_escaped_character?(index)
        backslashes = 0
        cursor = index - 1
        while cursor >= 0 && @editor_state.buffer[cursor] == "\\"
          backslashes += 1
          cursor -= 1
        end
        backslashes.odd?
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
        when "}"
          count.times { vibe_move_paragraph_forward }
        when "{"
          count.times { vibe_move_paragraph_backward }
        else
          @editor_state.status = "Unsupported motion: #{motion}"
          return false
        end
        true
      end

      def vibe_move_paragraph_forward
        line, = @editor_state.cursor_line_and_column
        lines = @editor_state.lines
        line += 1 while line < lines.length - 1 && !lines[line].to_s.strip.empty?
        line += 1 while line < lines.length - 1 && lines[line].to_s.strip.empty?
        @editor_state.set_cursor_line_and_column(line, 0)
      end

      def vibe_move_paragraph_backward
        line, = @editor_state.cursor_line_and_column
        lines = @editor_state.lines
        line -= 1 if line.positive?
        line -= 1 while line.positive? && lines[line].to_s.strip.empty?
        line -= 1 while line.positive? && !lines[line - 1].to_s.strip.empty?
        @editor_state.set_cursor_line_and_column(line, 0)
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
        @output_io.print(TerminalSequences.osc52(@editor_state.kill_buffer))
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
        return if [TerminalKeys::CTRL_C].include?(key)

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
