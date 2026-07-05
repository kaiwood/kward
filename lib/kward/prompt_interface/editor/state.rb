require_relative "../../editor_mode"
require_relative "../../text_boundary"
require_relative "buffer"
require_relative "file_marker"
require_relative "indent_navigation"
require_relative "kill_ring"
require_relative "undo_history"
require_relative "search"
require_relative "selections"
require_relative "status_text"
require_relative "vibe_state"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Mutable state for the built-in composer file editor.
    class EditorState
      attr_reader :path, :display_path, :language, :original_content, :original_digest, :original_mtime, :original_size
      attr_reader :buffer, :undo_stack, :redo_stack, :kill_buffer, :kill_ring, :last_yank_range, :last_yank_index
      attr_accessor :viewport_row, :viewport_column, :status, :overwrite_confirmed, :quit_confirmed, :search_active, :search_query, :search_direction, :new_file, :editor_mode, :emacs_pending, :readonly, :diff_view
      attr_reader :search_match_ranges

      def initialize(path:, content:, new_file: false, editor_mode: "modern", readonly: false, diff_view: false, virtual: false, display_path: nil, language: nil)
        @path = virtual ? nil : path.to_s
        @display_path = display_path.to_s.empty? ? path.to_s : display_path.to_s
        @language = language&.to_sym
        @new_file = new_file
        @readonly = readonly
        @diff_view = diff_view
        @virtual = virtual == true
        @file_marker = EditorFileMarker.new(path: @path || @display_path, content: content, new_file: new_file || virtual?)
        @original_content = @file_marker.content
        @original_digest = @file_marker.digest
        @original_mtime = @file_marker.mtime
        @original_size = @file_marker.size
        @text_buffer = EditorBuffer.new(@original_content)
        @buffer = @text_buffer.text
        @cursor = 0
        @viewport_row = 0
        @viewport_column = 0
        @status = nil
        @overwrite_confirmed = false
        @quit_confirmed = false
        @search = EditorSearch.new
        @search_active = @search.active?
        @search_query = @search.query
        @search_direction = @search.direction
        @search_match_ranges = []
        @kill_state = EditorKillRing.new
        @kill_buffer = @kill_state.kill_buffer
        @selections = EditorSelections.new(cursor: @cursor, buffer_length: @buffer.length)
        sync_selection_state
        @editor_mode = normalize_editor_mode(editor_mode)
        @emacs_pending = nil
        @kill_ring = @kill_state.kill_ring
        @last_yank_range = @kill_state.last_yank_range
        @last_yank_index = @kill_state.last_yank_index
        @vibe_state = VibeEditorState.new(editor_mode: @editor_mode)
        sync_vibe_state
        @undo_history = EditorUndoHistory.new
        @undo_stack = @undo_history.undo_stack
        @redo_stack = @undo_history.redo_stack
        @status = default_status
      end

      def initialize_copy(other)
        super
        @path = other.path&.dup
        @display_path = other.display_path.dup
        @language = other.language
        @virtual = other.virtual?
        @original_content = other.original_content.dup
        @file_marker = EditorFileMarker.new(path: @path || @display_path, content: @original_content, new_file: other.new_file || @virtual)
        @original_digest = other.original_digest.dup
        @original_mtime = other.original_mtime
        @original_size = other.original_size
        @text_buffer = EditorBuffer.new(other.buffer)
        @buffer = @text_buffer.text
        @status = other.status.dup
        @search = EditorSearch.new(direction: other.search_direction)
        @search_active = other.search_active
        @search_query = other.search_query.dup
        @search_direction = other.search_direction
        @search_match_ranges = other.search_match_ranges.map(&:dup)
        @kill_state = EditorKillRing.new(
          kill_buffer: other.kill_buffer.dup,
          kill_ring: other.kill_ring.map(&:dup),
          last_yank_range: other.last_yank_range&.dup,
          last_yank_index: other.last_yank_index
        )
        @kill_buffer = @kill_state.kill_buffer
        @quit_confirmed = other.quit_confirmed
        @viewport_column = other.viewport_column
        @selections = EditorSelections.new(
          cursor: @cursor,
          buffer_length: @buffer.length,
          anchor: other.selection_anchor,
          secondary: other.selections.drop(1).map(&:dup)
        )
        sync_selection_state
        @editor_mode = other.editor_mode.dup
        @emacs_pending = other.emacs_pending&.dup
        @kill_ring = @kill_state.kill_ring
        @last_yank_range = @kill_state.last_yank_range
        @last_yank_index = @kill_state.last_yank_index
        @vibe_state = VibeEditorState.copy(other.vibe_state)
        sync_vibe_state
        @undo_history = EditorUndoHistory.new
        other.undo_stack.each { |entry| @undo_history.undo_stack << duplicate_editor_snapshot(entry) }
        other.redo_stack.each { |entry| @undo_history.redo_stack << duplicate_editor_snapshot(entry) }
        @undo_stack = @undo_history.undo_stack
        @redo_stack = @undo_history.redo_stack
        @readonly = other.readonly
        @diff_view = other.diff_view
      end

      attr_reader :vibe_state

      def buffer=(value)
        @text_buffer.text = value
        @buffer = @text_buffer.text
        sync_selection_state if @selections
      end

      def undo_stack=(value)
        @undo_stack = value
        @undo_history = EditorUndoHistory.new(undo_stack: @undo_stack, redo_stack: @redo_stack)
      end

      def redo_stack=(value)
        @redo_stack = value
        @undo_history = EditorUndoHistory.new(undo_stack: @undo_stack, redo_stack: @redo_stack)
      end

      def kill_buffer=(value)
        @kill_state.kill_buffer = value
        sync_kill_state
      end

      def kill_ring=(value)
        @kill_state.kill_ring = value
        sync_kill_state
      end

      def last_yank_range=(value)
        @kill_state.last_yank_range = value
        sync_kill_state
      end

      def last_yank_index=(value)
        @kill_state.last_yank_index = value
        sync_kill_state
      end

      def vibe_mode
        @vibe_state.mode
      end

      def vibe_mode=(value)
        @vibe_state.mode = value
        sync_vibe_state
      end

      def vibe_pending
        @vibe_state.pending
      end

      def vibe_pending=(value)
        @vibe_state.pending = value
        sync_vibe_state
      end

      def vibe_command
        @vibe_state.command
      end

      def vibe_command=(value)
        @vibe_state.command = value
        sync_vibe_state
      end

      def vibe_last_change
        @vibe_state.last_change
      end

      def vibe_last_change=(value)
        @vibe_state.last_change = value
        sync_vibe_state
      end

      def vibe_last_find
        @vibe_state.last_find
      end

      def vibe_last_find=(value)
        @vibe_state.last_find = value
        sync_vibe_state
      end

      def vibe_last_visual_selection
        @vibe_state.last_visual_selection
      end

      def vibe_last_visual_selection=(value)
        @vibe_state.last_visual_selection = value
        sync_vibe_state
      end

      def vibe_visual_block_insert
        @vibe_state.visual_block_insert
      end

      def vibe_visual_block_insert=(value)
        @vibe_state.visual_block_insert = value
        sync_vibe_state
      end

      def vibe_marks
        @vibe_state.marks
      end

      def vibe_marks=(value)
        @vibe_state.marks = value
        sync_vibe_state
      end

      def vibe_registers
        @vibe_state.registers
      end

      def vibe_registers=(value)
        @vibe_state.registers = value
        sync_vibe_state
      end

      def vibe_register_types
        @vibe_state.register_types
      end

      def vibe_register_types=(value)
        @vibe_state.register_types = value
        sync_vibe_state
      end

      def vibe_kill_linewise
        @vibe_state.kill_linewise
      end

      def vibe_kill_linewise=(value)
        @vibe_state.kill_linewise = value
        sync_vibe_state
      end

      def vibe_previous_change_cursor
        @vibe_state.previous_change_cursor
      end

      def vibe_previous_change_cursor=(value)
        @vibe_state.previous_change_cursor = value
        sync_vibe_state
      end

      def vibe_jump_back_list
        @vibe_state.jump_back_list
      end

      def vibe_jump_back_list=(value)
        @vibe_state.jump_back_list = value
        sync_vibe_state
      end

      def vibe_jump_forward_list
        @vibe_state.jump_forward_list
      end

      def vibe_jump_forward_list=(value)
        @vibe_state.jump_forward_list = value
        sync_vibe_state
      end

      def vibe_macros
        @vibe_state.macros
      end

      def vibe_macros=(value)
        @vibe_state.macros = value
        sync_vibe_state
      end

      def vibe_recording_macro
        @vibe_state.recording_macro
      end

      def vibe_recording_macro=(value)
        @vibe_state.recording_macro = value
        sync_vibe_state
      end

      def vibe_last_macro
        @vibe_state.last_macro
      end

      def vibe_last_macro=(value)
        @vibe_state.last_macro = value
        sync_vibe_state
      end

      def cursor
        @cursor
      end

      def cursor=(value)
        @cursor = clamp_offset(value)
        @selections.cursor = @cursor
        sync_selection_state
      end

      def selection_anchor
        @selection_anchor
      end

      def selection_anchor=(value)
        @selections.anchor = value
        sync_selection_state
      end

      def selections
        sync_selection_state
        @selections.all
      end

      def multi_cursor?
        sync_selection_state
        @selections.multi_cursor?
      end

      def set_selections(values)
        @selections.set(values)
        @cursor = @selections.primary[:cursor]
        sync_selection_state
      end

      def add_selection(anchor, cursor = anchor)
        @selections.add(anchor, cursor)
        sync_selection_state
      end

      def collapse_to_primary_selection
        @selections.collapse_to_primary
        sync_selection_state
      end

      def secondary_cursor_offsets
        sync_selection_state
        @selections.secondary_cursor_offsets
      end

      def readonly?
        @readonly == true
      end

      def virtual?
        @virtual == true
      end

      def bind_path(path)
        @path = path.to_s
        @display_path = @path
        @virtual = false
        @new_file = !File.exist?(@path)
        @file_marker = EditorFileMarker.new(path: @path, content: @original_content, new_file: true)
      end

      def diff_view?
        @diff_view == true
      end

      def modern?
        @editor_mode == "modern"
      end

      def emacs?
        @editor_mode == "emacs"
      end

      def vibe?
        @editor_mode == "vibe"
      end

      def dirty?
        @buffer != @original_content
      end

      def lines
        @text_buffer.lines
      end

      def cursor_line_and_column
        cursor_line_and_column_for(@cursor)
      end

      def set_cursor_line_and_column(line_index, column)
        @cursor = offset_for_line_and_column(line_index, column)
      end

      def offset_for_line_and_column(line_index, column)
        @text_buffer.offset_for_line_and_column(line_index, column)
      end

      def push_undo
        @undo_history.push(editor_snapshot)
      end

      def undo
        snapshot = @undo_history.undo(editor_snapshot)
        unless snapshot
          @status = "Already at oldest change"
          return false
        end

        restore_editor_snapshot(snapshot)
        changed!
        @status = "Undo"
        true
      end

      def redo
        snapshot = @undo_history.redo(editor_snapshot)
        unless snapshot
          @status = "Already at newest change"
          return false
        end

        restore_editor_snapshot(snapshot)
        changed!
        @status = "Redo"
        true
      end

      def insert(text)
        text = text.to_s
        return if text.empty?
        return replace_selections(text) if multi_cursor?

        @text_buffer.insert(@cursor, text)
        @cursor += text.length
        @buffer = @text_buffer.text
        sync_selection_state
        changed!
      end

      def delete_before_cursor
        return delete_before_selections if multi_cursor?
        return false if @cursor.zero?

        @text_buffer.delete_range(@cursor - 1, @cursor)
        @cursor -= 1
        @buffer = @text_buffer.text
        sync_selection_state
        changed!
        true
      end

      def delete_at_cursor
        return delete_at_selections if multi_cursor?
        return false unless @cursor < @buffer.length

        @text_buffer.delete_range(@cursor, @cursor + 1)
        @buffer = @text_buffer.text
        sync_selection_state
        changed!
        true
      end

      def move_left
        if multi_cursor?
          return move_selection_cursors { |selection| [selection[:cursor] - 1, 0].max } if extending_selections?

          return move_selections { |selection| collapse_or_move_left(selection) }
        end

        @cursor -= 1 if @cursor.positive?
      end

      def move_right
        if multi_cursor?
          return move_selection_cursors { |selection| [selection[:cursor] + 1, @buffer.length].min } if extending_selections?

          return move_selections { |selection| collapse_or_move_right(selection) }
        end

        @cursor += 1 if @cursor < @buffer.length
      end

      def move_up
        if multi_cursor?
          return move_selection_cursors { |selection| move_offset_vertically(selection[:cursor], -1) } if extending_selections?

          return move_selections { |selection| move_offset_vertically(selection[:cursor], -1) }
        end

        line, column = cursor_line_and_column
        set_cursor_line_and_column(line - 1, column)
      end

      def move_down
        if multi_cursor?
          return move_selection_cursors { |selection| move_offset_vertically(selection[:cursor], 1) } if extending_selections?

          return move_selections { |selection| move_offset_vertically(selection[:cursor], 1) }
        end

        line, column = cursor_line_and_column
        set_cursor_line_and_column(line + 1, column)
      end

      def move_line_start
        if multi_cursor?
          return move_selection_cursors { |selection| line_start_for_offset(selection[:cursor]) } if extending_selections?

          return move_selections { |selection| line_start_for_offset(selection[:cursor]) }
        end

        line, = cursor_line_and_column
        set_cursor_line_and_column(line, 0)
      end

      def move_line_first_non_blank
        line, = cursor_line_and_column
        move_to_line_first_non_blank(line)
      end

      def move_to_line_first_non_blank(line_index)
        line = [[line_index.to_i, 0].max, lines.length - 1].min
        column = lines[line].to_s.index(/\S/) || 0
        set_cursor_line_and_column(line, column)
      end

      def move_line_end
        if multi_cursor?
          return move_selection_cursors { |selection| line_end_for_offset(selection[:cursor]) } if extending_selections?

          return move_selections { |selection| line_end_for_offset(selection[:cursor]) }
        end

        line, = cursor_line_and_column
        set_cursor_line_and_column(line, lines[line].length)
      end

      def page_up(rows)
        if multi_cursor?
          return move_selection_cursors { |selection| move_offset_vertically(selection[:cursor], -rows.to_i) } if extending_selections?

          return move_selections { |selection| move_offset_vertically(selection[:cursor], -rows.to_i) }
        end

        line, column = cursor_line_and_column
        set_cursor_line_and_column(line - rows.to_i, column)
      end

      def page_down(rows)
        if multi_cursor?
          return move_selection_cursors { |selection| move_offset_vertically(selection[:cursor], rows.to_i) } if extending_selections?

          return move_selections { |selection| move_offset_vertically(selection[:cursor], rows.to_i) }
        end

        line, column = cursor_line_and_column
        set_cursor_line_and_column(line + rows.to_i, column)
      end

      def move_to_previous_word
        if multi_cursor?
          return move_selection_cursors { |selection| previous_word_boundary(selection[:cursor]) } if extending_selections?

          return move_selections { |selection| previous_word_boundary(selection[:cursor]) }
        end

        @cursor = previous_word_boundary(@cursor)
      end

      def move_to_next_word
        if multi_cursor?
          return move_selection_cursors { |selection| next_word_boundary(selection[:cursor]) } if extending_selections?

          return move_selections { |selection| next_word_boundary(selection[:cursor]) }
        end

        @cursor = next_word_boundary(@cursor)
      end

      def move_to_word_end
        if multi_cursor?
          return move_selection_cursors { |selection| next_word_end(selection[:cursor]) } if extending_selections?

          return move_selections { |selection| next_word_end(selection[:cursor]) }
        end

        @cursor = next_word_end(@cursor)
      end

      def move_indentation_up
        if multi_cursor?
          return move_selection_cursors { |selection| indentation_offset_for(selection[:cursor], :up) } if extending_selections?

          return move_selections { |selection| indentation_offset_for(selection[:cursor], :up) }
        end

        line, column = cursor_line_and_column
        target_line = previous_indentation_line(line, indentation_level_for_line(line))
        move_to_indentation_line(target_line, column)
      end

      def move_indentation_down
        if multi_cursor?
          return move_selection_cursors { |selection| indentation_offset_for(selection[:cursor], :down) } if extending_selections?

          return move_selections { |selection| indentation_offset_for(selection[:cursor], :down) }
        end

        line, column = cursor_line_and_column
        target_line = next_indentation_line(line, indentation_level_for_line(line))
        move_to_indentation_line(target_line, column)
      end

      def move_indentation_right
        if multi_cursor?
          return move_selection_cursors { |selection| indentation_right_offset_for(selection[:cursor]) } if extending_selections?

          return move_selections { |selection| indentation_right_offset_for(selection[:cursor]) }
        end

        line, column = cursor_line_and_column
        indentation = indentation_level_for_line(line)
        if column < indentation
          set_cursor_line_and_column(line, indentation)
        else
          move_to_word_end
        end
      end

      def delete_word_before_cursor
        return apply_selection_edits { |selection| selection[:anchor] = previous_word_boundary(selection_range_for(selection)[0]); "" } if multi_cursor?

        kill_range(previous_word_boundary(@cursor), @cursor)
      end

      def delete_word_after_cursor
        return apply_selection_edits { |selection| selection[:cursor] = next_word_boundary(selection_range_for(selection)[1]); "" } if multi_cursor?

        kill_range(@cursor, next_word_boundary(@cursor))
      end

      def kill_line_before_cursor
        return apply_selection_edits { |selection| selection[:anchor] = line_start_for_offset(selection_range_for(selection)[0]); "" } if multi_cursor?

        kill_range(current_line_start, @cursor)
      end

      def kill_line_after_cursor
        if multi_cursor?
          return apply_selection_edits do |selection|
            range = selection_range_for(selection)
            selection[:cursor] = line_end_for_offset(range[1])
            selection[:cursor] += 1 if range[0] == selection[:cursor] && selection[:cursor] < @buffer.length
            ""
          end
        end

        if current_line_empty?
          kill_range(empty_line_start, empty_line_end)
        else
          kill_range(@cursor, current_line_end)
        end
      end

      def yank_kill_buffer
        replace_selections(@kill_buffer.to_s) unless @kill_buffer.to_s.empty?
      end

      def push_kill(text)
        return false unless @kill_state.push(text)

        sync_kill_state
        true
      end

      def yank_from_kill_ring
        text = @kill_state.first_yank
        return false unless text

        start_index = @cursor
        insert(text)
        @kill_state.record_yank(start_index, @cursor)
        sync_kill_state
        true
      end

      def yank_pop
        yank = @kill_state.next_yank_pop
        return false unless yank

        start_index, end_index = yank[:range]
        text = yank[:text]
        replace_range(start_index, end_index, text)
        @cursor = start_index + text.length
        @kill_state.record_yank_pop(start_index, @cursor)
        sync_kill_state
        true
      end

      def begin_selection
        self.selection_anchor = @cursor
        @status = "Selection started"
      end

      def clear_selection
        @selections.clear
        sync_selection_state
      end

      def selection_active?
        return false if @selection_anchor.nil?
        return true if vibe? && %w[visual visual_line visual_block].include?(@vibe_mode)

        @selection_anchor != @cursor
      end

      def selection_range
        return visual_line_selection_range if vibe? && @vibe_mode == "visual_line" && selection_active?
        return visual_character_selection_range if vibe? && @vibe_mode == "visual" && selection_active?
        return visual_block_selection_ranges.first if vibe? && @vibe_mode == "visual_block" && selection_active?
        return nil unless primary_selection_active?

        [@selection_anchor, @cursor].minmax
      end

      def selection_ranges
        if vibe? && %w[visual visual_line visual_block].include?(@vibe_mode) && selection_active?
          return visual_block_selection_ranges if @vibe_mode == "visual_block"

          return [selection_range]
        end

        selections.filter_map do |selection|
          range = selection_range_for(selection)
          range if range[0] != range[1]
        end
      end

      def visual_character_selection_range
        start_index, end_index = [@selection_anchor, @cursor].minmax
        [start_index, [end_index + 1, @buffer.length].min]
      end

      def visual_line_selection_range
        anchor_line, = cursor_line_and_column_for(@selection_anchor)
        cursor_line, = cursor_line_and_column
        start_line, end_line = [anchor_line, cursor_line].minmax
        start_index, = line_range(start_line)
        _, end_index = line_range(end_line)
        [start_index, end_index]
      end

      def visual_block_selection_ranges
        anchor_line, anchor_column = cursor_line_and_column_for(@selection_anchor)
        cursor_line, cursor_column = cursor_line_and_column
        start_line, end_line = [anchor_line, cursor_line].minmax
        start_column, end_column = [anchor_column, cursor_column].minmax
        (start_line..end_line).map do |line_index|
          line_start = line_start_offset(line_index)
          line_length = lines[line_index].to_s.length
          range_start = line_start + [start_column, line_length].min
          range_end = line_start + [end_column + 1, line_length].min
          [range_start, range_end]
        end
      end

      def selected_text
        if vibe? && @vibe_mode == "visual_block"
          return selection_ranges.map { |range| @buffer[range[0]...range[1]].to_s }.join("\n")
        end

        ranges = selection_ranges
        return "" if ranges.empty?

        ranges.map { |range| @buffer[range[0]...range[1]].to_s }.join("\n")
      end

      def cursor_line_and_column_for(offset)
        before_cursor = @buffer[0...offset].to_s
        [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
      end

      def line_start_offset(line_index)
        values = lines
        line_index = [[line_index.to_i, 0].max, values.length - 1].min
        values.first(line_index).sum { |line| line.length + 1 }
      end

      def line_range(line_index)
        start_index = line_start_offset(line_index)
        end_index = start_index + lines[line_index].to_s.length
        end_index += 1 if end_index < @buffer.length
        [start_index, end_index]
      end

      def word_range_at(offset)
        return nil if @buffer.empty?

        index = [[offset.to_i, 0].max, @buffer.length - 1].min
        return nil if word_separator?(@buffer[index])

        start_index = index
        start_index -= 1 while start_index.positive? && !word_separator?(@buffer[start_index - 1])
        end_index = index + 1
        end_index += 1 while end_index < @buffer.length && !word_separator?(@buffer[end_index])
        [start_index, end_index]
      end

      def current_line_range
        line, = cursor_line_and_column
        line_range(line)
      end

      def move_file_start
        @cursor = 0
      end

      def move_file_end
        @cursor = @buffer.length
      end

      def replace_range(start_index, end_index, text)
        start_index, = @text_buffer.replace_range(start_index, end_index, text)
        @buffer = @text_buffer.text
        @cursor = [start_index, @buffer.length].min
        changed!
      end

      def replace_selections(text)
        apply_selection_edits { |_selection| text.to_s }
      end

      def delete_before_selections
        apply_selection_edits do |selection|
          range = selection_range_for(selection)
          if range[0] != range[1]
            ""
          elsif range[0].positive?
            selection[:anchor] = range[0] - 1
            ""
          end
        end
      end

      def delete_at_selections
        apply_selection_edits do |selection|
          range = selection_range_for(selection)
          if range[0] != range[1]
            ""
          elsif range[1] < @buffer.length
            selection[:cursor] = range[1] + 1
            ""
          end
        end
      end

      def copy_range(start_index, end_index)
        start_index, end_index = [start_index, end_index].minmax
        self.kill_buffer = @buffer[start_index...end_index].to_s
      end

      def copy_for_kill_ring(start_index, end_index)
        start_index, end_index = [start_index, end_index].minmax
        push_kill(@buffer[start_index...end_index].to_s)
      end

      def cut_range(start_index, end_index)
        kill_range(start_index, end_index)
      end

      def add_next_occurrence_selection
        range = selection_range || word_range_at(@cursor)
        unless range
          @status = "No word under cursor"
          return false
        end

        query = @buffer[range[0]...range[1]].to_s
        if query.empty?
          @status = "No word under cursor"
          return false
        end

        existing_ranges = selection_ranges
        existing_ranges = [range] if existing_ranges.empty?
        start_after = existing_ranges.map(&:last).max || range[1]
        if selection_range.nil?
          set_selections([{ anchor: range[0], cursor: range[1] }])
          @status = "Selected: #{query}"
          return true
        end

        match = next_occurrence_range(query, start_after, existing_ranges)
        unless match
          @status = "No more matches: #{query}"
          return false
        end

        add_selection(match[0], match[1])
        @status = "Added cursor for: #{query}"
        true
      end

      def add_vertical_cursor(direction)
        source = direction == :up ? selections.min_by { |selection| selection[:cursor] } : selections.max_by { |selection| selection[:cursor] }
        line, column = cursor_line_and_column_for(source[:cursor])
        target_line = direction == :up ? line - 1 : line + 1
        if target_line.negative? || target_line >= lines.length
          @status = direction == :up ? "No line above" : "No line below"
          return false
        end

        target_column = [column, lines[target_line].to_s.length].min
        offset = line_start_offset(target_line) + target_column
        add_selection(offset, offset)
        @status = direction == :up ? "Added cursor above" : "Added cursor below"
        true
      end

      def selection_to_line_start_cursors
        range = selection_range
        unless range
          @status = "No selection"
          return false
        end

        start_line, = cursor_line_and_column_for(range[0])
        end_line, end_column = cursor_line_and_column_for(range[1])
        end_line -= 1 if end_column.zero? && end_line > start_line
        set_selections((start_line..end_line).map do |line_index|
          offset = line_start_offset(line_index)
          { anchor: offset, cursor: offset }
        end)
        @status = "Created #{selections.length} cursors"
        true
      end

      def extending_selections
        previous = @extending_selections
        @extending_selections = true
        yield
      ensure
        @extending_selections = previous
      end

      def begin_search(direction = :forward)
        @status = @search.begin(direction, cursor: @cursor)
        sync_search_state
        true
      end

      def cancel_search(restore_cursor: true)
        apply_search_result(@search.cancel(restore_cursor: restore_cursor))
        @search_match_ranges = []
        true
      end

      def clear_search_highlights
        @search_match_ranges = []
        true
      end

      def append_search(text)
        apply_search_result(@search.append(text, buffer: @buffer, cursor: @cursor))
      end

      def delete_search_character
        apply_search_result(@search.delete_character(buffer: @buffer, cursor: @cursor))
      end

      def confirm_search
        apply_search_result(@search.confirm(buffer: @buffer, cursor: @cursor))
      end

      def repeat_search(direction = @search_direction, query = @search_query)
        apply_search_result(@search.repeat(buffer: @buffer, cursor: @cursor, direction: direction, query: query))
      end

      def word_under_cursor
        return "" if @buffer.empty?

        index = [[@cursor, 0].max, @buffer.length - 1].min
        index -= 1 while index.positive? && word_separator?(@buffer[index])
        return "" if word_separator?(@buffer[index])

        start_index = index
        start_index -= 1 while start_index.positive? && !word_separator?(@buffer[start_index - 1])
        end_index = index + 1
        end_index += 1 while end_index < @buffer.length && !word_separator?(@buffer[end_index])
        @buffer[start_index...end_index].to_s
      end

      def refresh_after_save(content)
        @new_file = false
        @virtual = false
        @display_path = @path.to_s
        @file_marker.refresh(content)
        @original_content = @file_marker.content
        @original_digest = @file_marker.digest
        @original_mtime = @file_marker.mtime
        @original_size = @file_marker.size
        @overwrite_confirmed = false
        @quit_confirmed = false
        @status = "Saved #{@path}"
      end

      def file_changed_on_disk?
        return false if virtual?

        @file_marker.changed_on_disk?(new_file: new_file)
      end

      private

      def clamp_offset(value)
        [[value.to_i, 0].max, @buffer.length].min
      end

      def primary_selection
        sync_selection_state
        @selections.primary
      end

      def primary_selection_active?
        sync_selection_state
        @selections.primary_active?(vibe_visual: vibe? && %w[visual visual_line visual_block].include?(@vibe_mode))
      end

      def selection_range_for(selection)
        @selections.range_for(selection)
      end

      def editor_snapshot
        { buffer: @buffer.dup, selections: selections }
      end

      def restore_editor_snapshot(snapshot)
        self.buffer = snapshot[:buffer].to_s
        if snapshot[:selections]
          set_selections(snapshot[:selections])
        else
          set_selections([{ anchor: nil, cursor: [snapshot[:cursor].to_i, @buffer.length].min }])
          clear_selection
        end
      end

      def duplicate_editor_snapshot(snapshot)
        duplicate = { buffer: snapshot[:buffer].to_s.dup }
        if snapshot[:selections]
          duplicate[:selections] = snapshot[:selections].map(&:dup)
        else
          duplicate[:cursor] = snapshot[:cursor]
        end
        duplicate
      end

      def apply_selection_edits
        edits = selections.filter_map do |selection|
          edit_selection = selection.dup
          replacement = yield(edit_selection)
          next if replacement.nil?

          range = selection_range_for(edit_selection)
          { start: range[0], end: range[1], text: replacement.to_s }
        end
        return false if edits.empty?

        new_selections = []
        edits.sort_by { |edit| edit[:start] }.reverse_each do |edit|
          delta = edit[:text].length - (edit[:end] - edit[:start])
          new_selections.each do |selection|
            selection[:anchor] += delta if selection[:anchor] >= edit[:end]
            selection[:cursor] += delta if selection[:cursor] >= edit[:end]
          end
          @text_buffer.replace_range(edit[:start], edit[:end], edit[:text])
          @buffer = @text_buffer.text
          sync_selection_state
          cursor = edit[:start] + edit[:text].length
          new_selections << { anchor: cursor, cursor: cursor }
        end
        changed!(clear_selections: false)
        set_selections(new_selections.sort_by { |selection| [selection[:cursor], selection[:anchor]] })
        true
      end

      def next_occurrence_range(query, start_after, existing_ranges)
        ranges = occurrence_ranges(query, start_after) + occurrence_ranges(query, 0, limit: start_after)
        ranges.find { |range| existing_ranges.none? { |existing| existing == range } }
      end

      def occurrence_ranges(query, start_at, limit: @buffer.length)
        ranges = []
        index = @buffer.index(query, start_at)
        while index && index < limit
          range = [index, index + query.length]
          ranges << range if range[1] <= limit
          index = @buffer.index(query, index + query.length)
        end
        ranges
      end

      def kill_range(start_index, end_index)
        return false if start_index == end_index

        push_kill(@buffer[start_index...end_index].to_s)
        @text_buffer.delete_range(start_index, end_index)
        @buffer = @text_buffer.text
        @cursor = start_index
        sync_selection_state
        changed!
        true
      end

      def current_line_start
        line_start_for_offset(@cursor)
      end

      def current_line_end
        line_end_for_offset(@cursor)
      end

      def line_start_for_offset(offset)
        @buffer.rindex("\n", offset.to_i - 1)&.+(1) || 0
      end

      def line_end_for_offset(offset)
        @buffer.index("\n", offset.to_i) || @buffer.length
      end

      def move_selections
        set_selections(selections.map do |selection|
          offset = clamp_offset(yield(selection))
          { anchor: offset, cursor: offset }
        end)
      end

      def move_selection_cursors
        set_selections(selections.map do |selection|
          { anchor: selection[:anchor], cursor: clamp_offset(yield(selection)) }
        end)
      end

      def extending_selections?
        @extending_selections == true
      end

      def collapse_or_move_left(selection)
        range = selection_range_for(selection)
        return range[0] if range[0] != range[1]

        [selection[:cursor] - 1, 0].max
      end

      def collapse_or_move_right(selection)
        range = selection_range_for(selection)
        return range[1] if range[0] != range[1]

        [selection[:cursor] + 1, @buffer.length].min
      end

      def move_offset_vertically(offset, rows)
        line, column = cursor_line_and_column_for(offset)
        offset_for_line_and_column(line + rows.to_i, column)
      end

      def indentation_offset_for(offset, direction)
        line, column = cursor_line_and_column_for(offset)
        target_line = if direction == :up
          previous_indentation_line(line, indentation_level_for_line(line))
        else
          next_indentation_line(line, indentation_level_for_line(line))
        end
        return offset if target_line.nil?

        offset_for_line_and_column(target_line, column)
      end

      def indentation_right_offset_for(offset)
        line, column = cursor_line_and_column_for(offset)
        indentation = indentation_level_for_line(line)
        return offset_for_line_and_column(line, indentation) if column < indentation

        next_word_end(offset)
      end

      def current_line_empty?
        current_line_start == @cursor && current_line_end == @cursor
      end

      def empty_line_start
        current_line_end == @buffer.length && @cursor.positive? ? @cursor - 1 : @cursor
      end

      def empty_line_end
        current_line_end < @buffer.length ? current_line_end + 1 : current_line_end
      end

      def previous_word_boundary(index)
        TextBoundary.previous_word_boundary(@buffer, index)
      end

      def next_word_boundary(index)
        TextBoundary.next_word_boundary(@buffer, index)
      end

      def next_word_end(index)
        return 0 if @buffer.empty?

        cursor = [[index.to_i, 0].max, @buffer.length - 1].min
        cursor += 1 if cursor < @buffer.length - 1 && !word_separator?(@buffer[cursor])
        cursor += 1 while cursor < @buffer.length && word_separator?(@buffer[cursor])
        cursor += 1 while cursor < @buffer.length - 1 && !word_separator?(@buffer[cursor + 1])
        cursor
      end

      def indentation_level_for_line(line_index)
        indent_navigation.indentation_level_for_line(line_index)
      end

      def empty_line?(line_index)
        indent_navigation.empty_line?(line_index)
      end

      def move_to_indentation_line(line_index, column)
        return if line_index.nil?

        set_cursor_line_and_column(line_index, column)
      end

      def next_indentation_line(current_line, current_indentation)
        indent_navigation.next_line(current_line, current_indentation)
      end

      def previous_indentation_line(current_line, current_indentation)
        indent_navigation.previous_line(current_line, current_indentation)
      end

      def indent_navigation
        EditorIndentNavigation.new(lines)
      end

      def word_separator?(char)
        TextBoundary.word_separator?(char)
      end

      def sync_kill_state
        @kill_buffer = @kill_state.kill_buffer
        @kill_ring = @kill_state.kill_ring
        @last_yank_range = @kill_state.last_yank_range
        @last_yank_index = @kill_state.last_yank_index
      end

      def sync_selection_state
        @selections.buffer_length = @buffer.length
        @selections.cursor = @cursor
        @selection_anchor = @selections.anchor
      end

      def sync_search_state
        @search_active = @search.active?
        @search_query = @search.query
        @search_direction = @search.direction
        @search_match_ranges = EditorSearch.match_ranges(@buffer, @search_query)
      end

      def sync_vibe_state
        @vibe_mode = @vibe_state.mode
        @vibe_pending = @vibe_state.pending
        @vibe_command = @vibe_state.command
        @vibe_last_change = @vibe_state.last_change
        @vibe_last_find = @vibe_state.last_find
        @vibe_last_visual_selection = @vibe_state.last_visual_selection
        @vibe_visual_block_insert = @vibe_state.visual_block_insert
        @vibe_marks = @vibe_state.marks
        @vibe_registers = @vibe_state.registers
        @vibe_register_types = @vibe_state.register_types
        @vibe_kill_linewise = @vibe_state.kill_linewise
        @vibe_previous_change_cursor = @vibe_state.previous_change_cursor
        @vibe_jump_back_list = @vibe_state.jump_back_list
        @vibe_jump_forward_list = @vibe_state.jump_forward_list
        @vibe_macros = @vibe_state.macros
        @vibe_recording_macro = @vibe_state.recording_macro
        @vibe_last_macro = @vibe_state.last_macro
      end

      def apply_search_result(result)
        @cursor = result[:cursor] if result[:cursor]
        @status = result[:status]
        sync_search_state
        result[:found]
      end

      def normalize_editor_mode(value)
        EditorMode.normalize(value)
      end

      def default_status
        EditorStatusText.default(readonly: readonly?, editor_mode: @editor_mode)
      end

      def changed!(clear_selections: true)
        @overwrite_confirmed = false
        @quit_confirmed = false
        if clear_selections
          @selections.clear
          sync_selection_state
        end
        @kill_state.clear_last_yank
        sync_kill_state
      end
    end
  end
end
