require "fileutils"
require_relative "../../scratchpad_runner"

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
        if path
          opened = open_editor(path)
          add_history(history_file_open_command(path)) if opened
          return opened
        end
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

        opened = open_editor(file_open[:query], allow_new: true)
        add_history(history_file_open_command(file_open[:query])) if opened
        opened
      end

      def history_file_open_command(path)
        full_path = File.expand_path(path.to_s, prompt_workspace_root)
        relative_path = Pathname.new(full_path).relative_path_from(Pathname.new(prompt_workspace_root)).to_s
        "$#{relative_path}"
      rescue ArgumentError
        "$#{path}"
      end

      def open_scratchpad(language = :text, content: "")
        language = normalize_scratchpad_language(language)
        @editor_state = EditorState.new(
          path: scratchpad_display_path(language),
          display_path: scratchpad_display_path(language),
          content: content.to_s,
          new_file: true,
          editor_mode: current_editor_mode,
          virtual: true,
          language: language
        )
        @editor_state.status = scratchpad_status_text(language)
        @prompt_label = "Edit>"
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @pending_keys.clear
        @file_overlay_dismissed_token = nil
        @file_open_dismissed_token = nil
        @asking = true
        set_editor_bar_cursor_locked if current_editor_bar_cursor?
        enable_editor_mouse_reporting
        true
      end

      def open_editor(path, allow_new: false, base_dir: nil, restrict_to_workspace: true)
        full_path = File.expand_path(path.to_s, base_dir || prompt_workspace_root)
        root = prompt_workspace_root
        if restrict_to_workspace && !(full_path == root || full_path.start_with?("#{root}/"))
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
        set_editor_bar_cursor_locked if current_editor_bar_cursor?
        enable_editor_mouse_reporting
        true
      rescue StandardError => e
        @file_editor_open_status = "Cannot edit #{path}: #{e.message}"
        false
      end

      def open_diff_viewer(path, content)
        diff_view_mode = current_diff_view_mode
        viewer_content = diff_view_mode == DiffViewMode::SIDE_BY_SIDE ? side_by_side_diff_content(content.to_s) : content.to_s
        @editor_state = EditorState.new(path: path.to_s, content: viewer_content, new_file: true, editor_mode: current_editor_mode, readonly: true, diff_view: diff_view_mode)
        @prompt_label = "Diff>"
        self.composer_input = ""
        self.composer_cursor = 0
        @composer.clear_attachments
        @pending_keys.clear
        @asking = true
        enable_editor_mouse_reporting
        true
      end

      def current_editor_mode
        return normalize_editor_mode(@editor_mode_source.call) if @editor_mode_source.respond_to?(:call)

        @editor_mode
      rescue StandardError
        @editor_mode
      end

      def current_diff_view_mode
        configured = @diff_view_source.respond_to?(:call) ? @diff_view_source.call : @diff_view
        DiffViewMode.resolve(configured, terminal_width: screen_width)
      rescue StandardError
        DiffViewMode.resolve(@diff_view, terminal_width: screen_width)
      end

      def side_by_side_diff_content(content)
        width = side_by_side_diff_column_width
        rows = []
        pending_deletions = []

        content.to_s.each_line(chomp: true) do |line|
          if side_by_side_diff_metadata_line?(line)
            rows.concat(flush_side_by_side_deletions(pending_deletions, width))
            rows << line
          elsif line.start_with?("-")
            pending_deletions << line[1..].to_s
          elsif line.start_with?("+")
            deleted = pending_deletions.shift
            rows.concat(side_by_side_diff_rows(deleted && "- #{deleted}", "+ #{line[1..]}", width))
          else
            rows.concat(flush_side_by_side_deletions(pending_deletions, width))
            text = line.start_with?(" ") ? line[1..].to_s : line
            rows.concat(side_by_side_diff_rows("  #{text}", "  #{text}", width))
          end
        end

        rows.concat(flush_side_by_side_deletions(pending_deletions, width))
        rows.join("\n")
      end

      def side_by_side_diff_metadata_line?(line)
        line.start_with?("diff --git", "index ", "---", "+++", "@@")
      end

      def flush_side_by_side_deletions(lines, width)
        lines.shift(lines.length).flat_map { |line| side_by_side_diff_rows("- #{line}", nil, width) }
      end

      def side_by_side_diff_rows(left, right, width)
        return [side_by_side_diff_row(left, right, width)] unless current_editor_soft_wrap?

        left_lines = side_by_side_diff_cell_lines(left, width)
        right_lines = side_by_side_diff_cell_lines(right, width)
        [left_lines.length, right_lines.length].max.times.map do |index|
          side_by_side_diff_row(left_lines[index], right_lines[index], width)
        end
      end

      def side_by_side_diff_row(left, right, width)
        left_text = side_by_side_diff_cell(left, width)
        right_text = side_by_side_diff_cell(right, width)
        "#{left_text.ljust(width)} │ #{right_text}"
      end

      def side_by_side_diff_cell(text, width)
        value = text.nil? ? "" : text.to_s
        visible_truncate(value, width)
      end

      def side_by_side_diff_cell_lines(text, width)
        return [""] if text.nil?

        value = text.to_s
        prefix = value.start_with?("- ", "+ ", "  ") ? value[0, 2] : ""
        content = value.delete_prefix(prefix)
        return [prefix] if content.empty?

        content.chars.each_slice([width - prefix.length, 1].max).map { |characters| "#{prefix}#{characters.join}" }
      end

      def side_by_side_diff_column_width
        content_width = [screen_width - 4, 1].max
        gutter_width = [[999.to_s.length, 4].max + 3, 1].max
        [[(content_width - gutter_width - 3) / 2, 10].max, 80].min
      end

      def current_editor_soft_wrap?
        return @editor_soft_wrap_source.call != false if @editor_soft_wrap_source.respond_to?(:call)

        @editor_soft_wrap != false
      rescue StandardError
        @editor_soft_wrap != false
      end

      def current_editor_bar_cursor?
        return @editor_bar_cursor_source.call != false if @editor_bar_cursor_source.respond_to?(:call)

        @editor_bar_cursor != false
      rescue StandardError
        @editor_bar_cursor != false
      end

      def current_editor_line_numbers
        return normalize_editor_line_numbers(@editor_line_numbers_source.call) if @editor_line_numbers_source.respond_to?(:call)

        normalize_editor_line_numbers(@editor_line_numbers)
      rescue StandardError
        normalize_editor_line_numbers(@editor_line_numbers)
      end

      def close_editor
        disable_editor_mouse_reporting(force: true)
        restore_editor_cursor_shape_locked
        @editor_text_width = nil
        @editor_save_as_active = false
        @editor_save_as_buffer = ""
        @editor_save_callback = nil
        @editor_state = nil
        @prompt_label = "You>"
        self.composer_input = ""
        self.composer_cursor = 0
        restore_project_browser_after_editor_close
        @asking = true
      end

      def handle_editor_key(key)
        return if key.nil?
        mouse_result = handle_editor_mouse_key(key)
        return mouse_result unless mouse_result == false
        return handle_editor_save_as_key(key) if @editor_save_as_active
        return handle_readonly_editor_key(key) if @editor_state&.readonly?
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

        editor_tab_result = handle_editor_tab_key(key)
        return editor_tab_result unless editor_tab_result == false

        tab_result = handle_tab_key_binding(key)
        return tab_result unless tab_result == false

        return true if handle_bundled_key(key) { |token| handle_editor_key(token) }

        case key
        when "\n", "\r"
          return editor_search_confirm if editor_search_active?
          clear_editor_selection_before_edit
          editor_insert_newline
        when "\t"
          editor_insert_tab unless editor_search_active?
        when "\b", "\x7F"
          editor_search_active? ? editor_search_delete_character : delete_editor_selection || editor_delete_before_cursor
        when TerminalKeys::CTRL_C
          return editor_search_cancel if editor_search_active?
        when "\e"
          return editor_search_cancel if editor_search_active?
          return @editor_state.clear_selection if @editor_state.selection_active?
        when TerminalKeys::CTRL_Q
          quit_editor
        when TerminalKeys::CTRL_S
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
            editor_insert_printable(key)
          end
        end
      end

      def handle_editor_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        handle_parsed_editor_csi_u_key(sequence)
      end

      def handle_parsed_editor_csi_u_key(sequence)
        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        binding_result = handle_editor_modified_csi_u_key(code, modifier)
        return binding_result unless binding_result == false
        text = csi_u_printable_text(sequence)
        return editor_insert_csi_u_text(text) if text
        return true if csi_u_text_field?(sequence)

        case code
        when 9
          return false if editor_search_active?
          return false if ctrl_modifier?(modifier) || alt_modifier?(modifier) || super_modifier?(modifier)

          shift_modifier?(modifier) ? editor_outdent_tab : editor_insert_tab
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
          false
        end
      end

      def editor_insert_csi_u_text(text)
        if editor_search_active?
          editor_search_append(text)
        else
          editor_insert_printable(text)
        end
      end

      def handle_editor_search_csi_u_key(sequence, enter: :confirm, restore_cursor_on_cancel: true)
        result = case sequence[:code]
                 when 13
                   if enter == :repeat
                     shift_modifier?(sequence[:modifier]) ? editor_search_repeat(:backward) : editor_search_repeat(:forward)
                   else
                     editor_search_confirm
                   end
                 when 27
                   editor_search_cancel(restore_cursor: restore_cursor_on_cancel)
                 when 8, 127
                   editor_search_delete_character
                 else
                   normalized_code = ctrl_code(sequence[:code])
                   if ctrl_modifier?(sequence[:modifier]) && normalized_code == 103
                     shift_modifier?(sequence[:modifier]) ? editor_search_repeat(:backward) : editor_search_repeat(:forward)
                   elsif (text = csi_u_printable_text(sequence))
                     editor_search_append(text)
                   elsif csi_u_text_field?(sequence)
                     true
                   else
                     false
                   end
                 end
        queue_pending_keys(sequence[:remaining]) if result != false && sequence[:remaining] && !sequence[:remaining].empty?
        result
      end

      def handle_editor_mouse_key(key)
        event = parse_editor_mouse_key(key)
        return false unless event

        queue_pending_keys(event[:remaining]) unless event[:remaining].empty?
        case event[:code]
        when 64
          scroll_editor_up(editor_mouse_scroll_rows)
        when 65
          scroll_editor_down(editor_mouse_scroll_rows)
        else
          if event[:drag]
            handle_editor_mouse_drag(event)
          elsif event[:button].zero?
            event[:release] ? finish_editor_mouse_drag : handle_editor_mouse_press(event)
          else
            true
          end
        end
      end

      def parse_editor_mouse_key(key)
        parse_sgr_mouse_event(key)
      end

      def handle_editor_mouse_press(event)
        position = editor_position_for_mouse_event(event)
        return true unless position

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        click_count = editor_mouse_click_count(event, now)
        case click_count
        when 3..Float::INFINITY
          range = select_editor_line_at(position[:line])
          @editor_mouse_drag_anchor = range[0]
          @editor_mouse_dragging = true
        when 2
          range = select_editor_word_at(position[:offset])
          if range
            @editor_mouse_drag_anchor = range[0]
            @editor_mouse_dragging = true
          else
            finish_editor_mouse_drag
          end
        else
          @editor_state.clear_selection
          @editor_state.cursor = position[:offset]
          @editor_mouse_drag_anchor = position[:offset]
          @editor_mouse_dragging = true
        end
        @editor_last_click = { time: now, column: event[:column], row: event[:row], count: click_count }
        true
      end

      def handle_editor_mouse_drag(event)
        return true unless @editor_mouse_dragging

        position = editor_drag_position_for_mouse_event(event)
        return true unless position

        @editor_state.selection_anchor = @editor_mouse_drag_anchor
        @editor_state.cursor = position[:offset]
        true
      end

      def finish_editor_mouse_drag
        @editor_mouse_dragging = false
        @editor_mouse_drag_anchor = nil
        true
      end

      def editor_mouse_click_count(event, now)
        return 1 unless editor_repeated_click?(event, now)

        @editor_last_click[:count].to_i + 1
      end

      def editor_repeated_click?(event, now)
        return false unless @editor_last_click
        return false unless now - @editor_last_click[:time] <= 0.5

        (@editor_last_click[:column] - event[:column]).abs <= 1 && (@editor_last_click[:row] - event[:row]).abs <= 1
      end

      def select_editor_word_at(offset)
        range = @editor_state.word_range_at(offset)
        return @editor_state.clear_selection unless range

        @editor_state.selection_anchor = range[0]
        @editor_state.cursor = range[1]
        range
      end

      def select_editor_line_at(line_index)
        range = @editor_state.line_range(line_index)
        @editor_state.selection_anchor = range[0]
        @editor_state.cursor = range[1]
        range
      end

      def editor_drag_position_for_mouse_event(event)
        scroll_editor_horizontally_for_drag(event)
        top = editor_mouse_content_top_row
        bottom = top + editor_visible_line_count - 1
        if event[:row] < top
          scroll_editor_up(editor_mouse_scroll_rows)
          return editor_edge_position_for_mouse_event(event, @editor_state.viewport_row)
        elsif event[:row] > bottom
          scroll_editor_down(editor_mouse_scroll_rows)
          return editor_edge_position_for_mouse_event(event, @editor_state.viewport_row + editor_visible_line_count - 1)
        end

        editor_position_for_mouse_event(event)
      end

      def editor_position_for_mouse_event(event)
        row_offset = event[:row] - editor_mouse_content_top_row
        return nil if row_offset.negative? || row_offset >= editor_visible_line_count

        if current_editor_soft_wrap?
          editor_wrapped_position_for_mouse(event, row_offset)
        else
          line_index = @editor_state.viewport_row + row_offset
          editor_position_for_line_and_column(line_index, editor_mouse_column_for_event(event))
        end
      end

      def editor_wrapped_position_for_mouse(event, row_offset)
        editor_wrapped_position_for_visual_row(event, @editor_state.viewport_row + row_offset)
      end

      def editor_edge_position_for_mouse_event(event, row_index)
        if current_editor_soft_wrap?
          editor_wrapped_position_for_visual_row(event, row_index)
        else
          editor_position_for_line_and_column(row_index, editor_mouse_column_for_event(event))
        end
      end

      def editor_wrapped_position_for_visual_row(event, row_index)
        visual_row = editor_visual_rows(current_editor_text_width)[row_index]
        return nil unless visual_row

        column = visual_row[:column_offset] + editor_mouse_column_for_event(event)
        editor_position_for_line_and_column(visual_row[:line_index], column)
      end

      def editor_position_for_line_and_column(line_index, column)
        lines = @editor_state.lines
        line_index = [[line_index.to_i, 0].max, lines.length - 1].min
        column = [[column.to_i, 0].max, lines[line_index].to_s.length].min
        @editor_state.set_cursor_line_and_column(line_index, column)
        { line: line_index, column: column, offset: @editor_state.cursor }
      end

      def editor_bottom_mouse_line_index
        [@editor_state.viewport_row + editor_visible_line_count - 1, @editor_state.lines.length - 1].min
      end

      def scroll_editor_horizontally_for_drag(event)
        return if current_editor_soft_wrap?

        if event[:column] < editor_mouse_text_left_column
          @editor_state.viewport_column = [@editor_state.viewport_column.to_i - editor_mouse_scroll_rows, 0].max
        elsif event[:column] > editor_mouse_text_right_column
          @editor_state.viewport_column = @editor_state.viewport_column.to_i + editor_mouse_scroll_rows
        end
      end

      def editor_mouse_column_for_event(event)
        column = [event[:column] - editor_mouse_text_left_column, 0].max
        current_editor_soft_wrap? ? column : column + @editor_state.viewport_column.to_i
      end

      def editor_mouse_text_left_column
        3 + editor_line_number_gutter_width
      end

      def editor_mouse_text_right_column
        editor_mouse_text_left_column + current_editor_text_width - 1
      end

      def editor_mouse_content_top_row
        3
      end

      def handle_editor_shift_navigation_key(key)
        return false if editor_search_active?

        case key
        when *TerminalKeys::SHIFT_LEFT
          editor_extending_selection { @editor_state.move_left }
        when *TerminalKeys::SHIFT_RIGHT
          editor_extending_selection { @editor_state.move_right }
        when *TerminalKeys::SHIFT_UP
          editor_extending_selection { editor_move_up }
        when *TerminalKeys::SHIFT_DOWN
          editor_extending_selection { editor_move_down }
        else
          false
        end
      end

      def handle_editor_key_binding(key)
        case key
        when TerminalKeys::CTRL_A
          @editor_state.move_line_start unless editor_search_active?
        when TerminalKeys::CTRL_B
          @editor_state.move_left unless editor_search_active?
        when TerminalKeys::CTRL_D
          @editor_state.delete_at_cursor unless editor_search_active?
        when TerminalKeys::CTRL_E
          @editor_state.move_line_end unless editor_search_active?
        when TerminalKeys::CTRL_F
          @editor_state.move_right unless editor_search_active?
        when TerminalKeys::CTRL_SPACE
          @editor_state.begin_selection unless editor_search_active?
        when TerminalKeys::CTRL_K
          @editor_state.kill_line_after_cursor unless editor_search_active?
        when TerminalKeys::CTRL_N
          editor_move_down unless editor_search_active?
        when TerminalKeys::CTRL_P
          editor_move_up unless editor_search_active?
        when TerminalKeys::CTRL_U
          @editor_state.kill_line_before_cursor unless editor_search_active?
        when TerminalKeys::CTRL_W
          @editor_state.delete_word_before_cursor unless editor_search_active?
        when TerminalKeys::CTRL_Y
          editor_selection_active? ? copy_editor_selection : @editor_state.yank_kill_buffer unless editor_search_active?
        when *TerminalKeys::LEFT
          @editor_state.move_left unless editor_search_active?
        when *TerminalKeys::RIGHT
          @editor_state.move_right unless editor_search_active?
        when *TerminalKeys::HOME
          @editor_state.move_line_start unless editor_search_active?
        when *TerminalKeys::END_KEY
          @editor_state.move_line_end unless editor_search_active?
        when *TerminalKeys::DELETE
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
            editor_move_down unless editor_search_active?
          when 112
            editor_move_up unless editor_search_active?
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
        sequence = parse_modified_ansi_key(key)
        return false unless sequence

        case sequence[:type]
        when :cursor
          return false unless alt_modifier?(sequence[:modifier])

          case sequence[:final]
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
        when :delete
          if alt_modifier?(sequence[:modifier])
            @editor_state.delete_word_after_cursor unless editor_search_active?
          else
            @editor_state.delete_at_cursor unless editor_search_active?
          end
        else
          false
        end
      end

      def handle_editor_bracketed_paste_key(key)
        handle_bracketed_paste(key) do |content|
          @editor_state.insert(content) unless editor_search_active?
        end
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
            editor_move_up
          when :down
            editor_move_down
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

      def handle_readonly_editor_key(key)
        return if handle_readonly_bracketed_paste_key(key)

        return true if handle_bundled_key(key) { |token| handle_readonly_editor_key(token) }

        key_name = key_name_for(key)
        named_result = handle_readonly_named_key(key_name) if key_name
        return named_result unless named_result == false || named_result.nil?

        case key
        when TerminalKeys::CTRL_Q
          close_editor
        when TerminalKeys::CTRL_F
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        when TerminalKeys::CTRL_C
          editor_search_active? ? editor_search_cancel : copy_editor_selection
        when "/"
          editor_search_active? ? editor_search_append(key) : editor_search_begin
        when "\b", "\x7F"
          editor_search_delete_character if editor_search_active?
        when "\n", "\r"
          editor_search_confirm if editor_search_active?
        when "\e"
          editor_search_active? ? editor_search_cancel : close_editor
        else
          csi_result = handle_readonly_csi_u_key(key)
          return csi_result unless csi_result == false

          if editor_search_active?
            editor_search_append(key) if printable_key?(key)
          elsif printable_key?(key)
            @editor_state.status = "Read-only diff"
          end
        end
      end

      def handle_readonly_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        code = sequence[:code]
        modifier = sequence[:modifier]
        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?

        if ctrl_modifier?(modifier) && ctrl_code(code) == 113
          return close_editor
        end

        if ctrl_modifier?(modifier) && ctrl_code(code) == 102
          return editor_search_active? ? editor_search_append(key) : editor_search_begin
        end

        if (ctrl_modifier?(modifier) || super_modifier?(modifier)) && ctrl_code(code) == 99
          return editor_search_active? ? editor_search_cancel : copy_editor_selection
        end

        case code
        when 13
          editor_search_confirm if editor_search_active?
        when 27
          editor_search_active? ? editor_search_cancel : close_editor
        when 8, 127
          editor_search_delete_character if editor_search_active?
        else
          return false unless editor_search_active?

          text = csi_u_printable_text(sequence)
          return true if text.nil? && csi_u_text_field?(sequence)
          return false unless text

          editor_search_append(text)
        end
      end

      def handle_readonly_bracketed_paste_key(key)
        handle_bracketed_paste(key) do |_content|
          @editor_state.status = "Read-only diff" unless editor_search_active?
        end
      end

      def handle_readonly_named_key(key_name)
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
          when :left
            @editor_state.move_left
          when :right
            @editor_state.move_right
          when :up
            editor_move_up
          when :down
            editor_move_down
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
        if @editor_state.multi_cursor?
          @editor_state.extending_selections { yield }
        else
          @editor_state.selection_anchor ||= @editor_state.cursor
          yield
        end
        true
      end

      def editor_move_up
        return @editor_state.move_up unless current_editor_soft_wrap?

        line, column = @editor_state.cursor_line_and_column
        text_width = current_editor_text_width
        row_start = editor_visual_row_start_column(line, column, text_width)
        visual_column = column - row_start
        if row_start.positive?
          target_column = row_start - text_width + visual_column
          return @editor_state.set_cursor_line_and_column(line, target_column)
        end

        return @editor_state.move_up if line.zero?

        previous_line = @editor_state.lines[line - 1].to_s
        previous_row_start = editor_last_visual_row_start_column(previous_line, text_width)
        target_column = [previous_row_start + visual_column, previous_line.length].min
        @editor_state.set_cursor_line_and_column(line - 1, target_column)
      end

      def editor_move_down
        return @editor_state.move_down unless current_editor_soft_wrap?

        line, column = @editor_state.cursor_line_and_column
        text_width = current_editor_text_width
        row_start = editor_visual_row_start_column(line, column, text_width)
        visual_column = column - row_start
        next_start = row_start + text_width
        current_line = @editor_state.lines[line].to_s
        if next_start < current_line.length
          target_column = [next_start + visual_column, current_line.length].min
          return @editor_state.set_cursor_line_and_column(line, target_column)
        end

        return @editor_state.move_down if line >= @editor_state.lines.length - 1

        next_line = @editor_state.lines[line + 1].to_s
        target_column = [visual_column, next_line.length].min
        @editor_state.set_cursor_line_and_column(line + 1, target_column)
      end

      def editor_last_visual_row_start_column(line, text_width)
        length = line.to_s.length
        return 0 if length.zero?

        ((length - 1) / text_width) * text_width
      end

      def current_editor_text_width
        return @editor_text_width if @editor_text_width

        content_width = [screen_width - 4, 1].max
        editor_text_width(content_width)
      end

      def sync_editor_wrap_state(text_width = current_editor_text_width)
        return unless @editor_state

        @editor_text_width = text_width
        @editor_state.viewport_column = 0 if current_editor_soft_wrap?
        text_width
      end

      def editor_selection_active?
        @editor_state&.selection_active?
      end

      def clear_editor_selection_before_edit
        @editor_state&.clear_selection
      end

      def delete_editor_selection
        return false unless @editor_state.selection_ranges.any?

        @editor_state.replace_selections("")
        true
      end

      def copy_editor_selection
        text = @editor_state.selected_text
        return false if text.empty?

        @editor_state.push_kill(text)
        print_output_locked(TerminalSequences.osc52(text))
        flush_output_locked if @output_io.respond_to?(:flush)
        @editor_state.clear_selection
        @editor_state.status = "Copied selection"
        true
      end

      def cut_editor_selection
        text = @editor_state.selected_text
        return false if text.empty?

        @editor_state.push_kill(text)
        @editor_state.replace_selections("")
        @editor_state.status = "Cut selection"
        true
      end

      def editor_search_active?
        @editor_state&.search_active
      end

      def editor_search_begin(direction = :forward)
        @editor_state.begin_search(direction)
        ensure_editor_cursor_visible
        true
      end

      def editor_search_append(text)
        @editor_state.append_search(text)
        ensure_editor_cursor_visible
        true
      end

      def editor_search_delete_character
        @editor_state.delete_search_character
        ensure_editor_cursor_visible
        true
      end

      def editor_search_confirm(clear_highlights: true)
        @editor_state.confirm_search
        @editor_state.clear_search_highlights if clear_highlights
        ensure_editor_cursor_visible
        true
      end

      def editor_search_cancel(restore_cursor: true)
        @editor_state.cancel_search(restore_cursor: restore_cursor)
        ensure_editor_cursor_visible
        true
      end

      def editor_search_repeat(direction = nil)
        direction ||= @editor_state.search_direction
        @editor_state.repeat_search(direction)
        @editor_state.clear_search_highlights unless @editor_state.search_active
        ensure_editor_cursor_visible
        true
      end

      def editor_search_word_under_cursor(direction = :forward)
        query = @editor_state.word_under_cursor
        if query.empty?
          @editor_state.status = "No word under cursor"
          return true
        end

        @editor_state.repeat_search(direction, query)
        @editor_state.clear_search_highlights
        ensure_editor_cursor_visible
        true
      end

      def ensure_editor_cursor_visible
        return false unless @editor_state

        content_width = [screen_width - 4, 1].max
        visible_count = editor_visible_line_count
        line_index, column = @editor_state.cursor_line_and_column
        gutter_width = editor_line_number_gutter_width
        text_width = editor_text_width(content_width, gutter_width)
        sync_editor_wrap_state(text_width)

        if current_editor_soft_wrap?
          cursor_visual_row = editor_visual_row_for(line_index, column, text_width)
          @editor_state.viewport_row = [[@editor_state.viewport_row, cursor_visual_row - visible_count + 1].max, cursor_visual_row].min
          @editor_state.viewport_row = [@editor_state.viewport_row, 0].max
        else
          @editor_state.viewport_row = [[@editor_state.viewport_row, line_index - visible_count + 1].max, line_index].min
          @editor_state.viewport_row = [@editor_state.viewport_row, 0].max
          @editor_state.viewport_column = [[@editor_state.viewport_column.to_i, column - text_width + 1].max, column].min
          @editor_state.viewport_column = [@editor_state.viewport_column, 0].max
        end
        true
      end

      def editor_page_rows
        [editor_visible_line_count, 1].max
      end

      def editor_scroll_page_rows
        [editor_visible_line_count / 2, 1].max
      end

      def editor_mouse_scroll_rows
        1
      end

      def enable_editor_mouse_reporting
        return if @editor_mouse_reporting_enabled

        print_output_locked(TerminalSequences::MOUSE_REPORTING_ENABLE)
        flush_output_locked if @output_io.respond_to?(:flush)
        @editor_mouse_reporting_enabled = true
      end

      def disable_editor_mouse_reporting(force: false)
        return unless force || @editor_mouse_reporting_enabled

        print_output_locked(TerminalSequences::MOUSE_REPORTING_DISABLE)
        flush_output_locked if @output_io.respond_to?(:flush)
        @editor_mouse_reporting_enabled = false
      end

      def scroll_editor_up(rows)
        visible_count = editor_visible_line_count
        @editor_state.viewport_row = [@editor_state.viewport_row - rows.to_i, 0].max
        keep_editor_cursor_in_view(visible_count)
      end

      def scroll_editor_down(rows)
        visible_count = editor_visible_line_count
        last_top_row = if current_editor_soft_wrap?
          [editor_visual_rows(current_editor_text_width).length - visible_count, 0].max
        else
          [@editor_state.lines.length - visible_count, 0].max
        end
        @editor_state.viewport_row = [@editor_state.viewport_row + rows.to_i, last_top_row].min
        keep_editor_cursor_in_view(visible_count)
      end

      def keep_editor_cursor_in_view(visible_count)
        line, column = @editor_state.cursor_line_and_column
        if current_editor_soft_wrap?
          text_width = current_editor_text_width
          top_row = @editor_state.viewport_row
          bottom_row = top_row + visible_count - 1
          while editor_visual_row_for(*@editor_state.cursor_line_and_column, text_width) > bottom_row && @editor_state.cursor.positive?
            editor_move_up
          end
          while editor_visual_row_for(*@editor_state.cursor_line_and_column, text_width) < top_row && @editor_state.cursor < @editor_state.buffer.length
            editor_move_down
          end
          return true
        end

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

      def save_editor(path = nil, prompt_for_path: true)
        return false unless @editor_state
        if @editor_state.readonly?
          @editor_state.status = "Read-only diff"
          return true
        end

        if @editor_save_callback
          result = @editor_save_callback.call(@editor_state.buffer)
          if result.to_s.empty?
            close_editor
            return true
          end

          @editor_state.status = result.to_s
          return false
        end

        if path.to_s.strip.empty? && @editor_state.path.to_s.empty?
          if prompt_for_path
            begin_editor_save_as
            return true
          end

          @editor_state.status = "Use :w filename"
          return false
        end

        return false if !path.to_s.strip.empty? && !bind_editor_save_path(path)

        if @editor_state.file_changed_on_disk? && !@editor_state.overwrite_confirmed
          @editor_state.overwrite_confirmed = true
          @editor_state.status = "File changed on disk. Press Ctrl+S again to overwrite."
          return true
        end

        parent = File.dirname(@editor_state.path)
        FileUtils.mkdir_p(parent) unless Dir.exist?(parent)
        File.write(@editor_state.path, @editor_state.buffer)
        @editor_state.refresh_after_save(@editor_state.buffer)
        true
      rescue StandardError => e
        @editor_state.status = "Save failed: #{e.message}" if @editor_state
        false
      end

      def begin_editor_save_as
        @editor_save_as_active = true
        @editor_save_as_buffer = ""
        @editor_state.status = "Save as: "
        true
      end

      def handle_editor_save_as_key(key)
        return true if handle_bundled_key(key) { |token| handle_editor_save_as_key(token) }

        csi_result = handle_editor_save_as_csi_u_key(key)
        return csi_result unless csi_result == false

        case key
        when "\n", "\r"
          finish_editor_save_as
        when "\e", TerminalKeys::CTRL_C
          cancel_editor_save_as
        when "\b", "\x7F"
          @editor_save_as_buffer = @editor_save_as_buffer.to_s[0...-1]
          update_editor_save_as_status
        else
          key_name = key_name_for(key)
          case key_name
          when :return, :enter
            finish_editor_save_as
          when :backspace
            @editor_save_as_buffer = @editor_save_as_buffer.to_s[0...-1]
            update_editor_save_as_status
          else
            if printable_key?(key)
              @editor_save_as_buffer = @editor_save_as_buffer.to_s + key
              update_editor_save_as_status
            end
          end
        end
        true
      end

      def handle_editor_save_as_csi_u_key(key)
        sequence = parse_csi_u_key(key)
        return false unless sequence

        queue_pending_keys(sequence[:remaining]) if sequence[:remaining] && !sequence[:remaining].empty?
        code = sequence[:code]
        modifier = sequence[:modifier]
        normalized_code = ctrl_code(code)
        if code == 13
          return finish_editor_save_as
        elsif [8, 127].include?(code)
          @editor_save_as_buffer = @editor_save_as_buffer.to_s[0...-1]
          return update_editor_save_as_status
        elsif code == 27 || (ctrl_modifier?(modifier) && normalized_code == 99)
          return cancel_editor_save_as
        end

        text = csi_u_printable_text(sequence)
        if text
          @editor_save_as_buffer = @editor_save_as_buffer.to_s + text
          return update_editor_save_as_status
        end

        true
      end

      def finish_editor_save_as
        path = @editor_save_as_buffer.to_s.strip
        @editor_save_as_active = false
        @editor_save_as_buffer = ""
        if path.empty?
          @editor_state.status = "Save canceled"
          return true
        end

        save_editor(path, prompt_for_path: false)
      end

      def cancel_editor_save_as
        @editor_save_as_active = false
        @editor_save_as_buffer = ""
        @editor_state.status = "Save canceled"
        true
      end

      def update_editor_save_as_status
        @editor_state.status = "Save as: #{@editor_save_as_buffer}"
        true
      end

      def bind_editor_save_path(path)
        full_path = File.expand_path(path.to_s.strip, prompt_workspace_root)
        root = prompt_workspace_root
        unless full_path == root || full_path.start_with?("#{root}/")
          @editor_state.status = "Cannot save outside workspace"
          return false
        end

        @editor_state.bind_path(full_path)
        @editor_syntax_language_path = nil
        @editor_indent_unit_path = nil
        true
      end

      def run_editor_buffer
        return false unless @editor_state

        language = @editor_state.language || editor_syntax_language
        result = ScratchpadRunner.run(language, @editor_state.buffer)
        @editor_state.replace_range(0, @editor_state.buffer.length, result.buffer)
        @editor_state.status = "Ran #{language} (exit #{result.exit_status})"
        true
      rescue StandardError => e
        @editor_state.status = "Run failed: #{e.message}" if @editor_state
        false
      end

      def normalize_scratchpad_language(language)
        case language.to_s.strip.downcase
        when "", "text", "txt"
          :text
        when "markdown", "md"
          :markdown
        when "ruby", "rb"
          :ruby
        else
          :text
        end
      end

      def scratchpad_display_path(language)
        case language.to_sym
        when :markdown
          "scratchpad.md"
        when :ruby
          "scratchpad.rb"
        else
          "scratchpad.txt"
        end
      end

      def scratchpad_status_text(language)
        runnable = language.to_sym == :ruby
        case current_editor_mode
        when "vibe"
          runnable ? "NORMAL · i insert · :w filename save · :q quit · :run run" : "NORMAL · i insert · :w filename save · :q quit"
        when "emacs"
          runnable ? "C-x C-s save as · C-x C-c quit · C-r run" : "C-x C-s save as · C-x C-c quit"
        else
          runnable ? "Ctrl+S save as · Ctrl+Q quit · Ctrl+R run" : "Ctrl+S save as · Ctrl+Q quit"
        end
      end

      def printable_key?(key)
        key.is_a?(String) && key.length == 1 && key.match?(/[[:print:]]/)
      end
    end
  end
end
