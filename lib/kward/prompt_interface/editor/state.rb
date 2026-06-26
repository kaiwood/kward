require_relative "../../editor_mode"
require_relative "../../text_boundary"
require_relative "file_marker"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Mutable state for the built-in composer file editor.
    class EditorState
      attr_reader :path, :original_content, :original_digest, :original_mtime, :original_size
      attr_reader :buffer
      attr_accessor :viewport_row, :viewport_column, :status, :overwrite_confirmed, :quit_confirmed, :search_active, :search_query, :search_direction, :new_file, :kill_buffer, :editor_mode, :emacs_pending, :kill_ring, :last_yank_range, :last_yank_index, :vibe_mode, :vibe_pending, :vibe_command, :undo_stack, :redo_stack, :vibe_last_change, :vibe_last_find, :vibe_last_visual_selection, :vibe_visual_block_insert, :vibe_marks, :vibe_registers, :vibe_macros, :vibe_recording_macro, :vibe_last_macro, :readonly, :diff_view

      def initialize(path:, content:, new_file: false, editor_mode: "modern", readonly: false, diff_view: false)
        @path = path.to_s
        @new_file = new_file
        @readonly = readonly
        @diff_view = diff_view
        @file_marker = EditorFileMarker.new(path: @path, content: content, new_file: new_file)
        @original_content = @file_marker.content
        @original_digest = @file_marker.digest
        @original_mtime = @file_marker.mtime
        @original_size = @file_marker.size
        @buffer = @original_content.dup
        @cursor = 0
        @viewport_row = 0
        @viewport_column = 0
        @status = nil
        @overwrite_confirmed = false
        @quit_confirmed = false
        @search_active = false
        @search_query = ""
        @search_direction = :forward
        @kill_buffer = ""
        @selection_anchor = nil
        @secondary_selections = []
        @editor_mode = normalize_editor_mode(editor_mode)
        @emacs_pending = nil
        @kill_ring = []
        @last_yank_range = nil
        @last_yank_index = nil
        @vibe_mode = @editor_mode == "vibe" ? "normal" : nil
        @vibe_pending = ""
        @vibe_command = ""
        @undo_stack = []
        @redo_stack = []
        @vibe_last_change = nil
        @vibe_last_find = nil
        @vibe_last_visual_selection = nil
        @vibe_visual_block_insert = nil
        @vibe_marks = {}
        @vibe_registers = {}
        @vibe_macros = {}
        @vibe_recording_macro = nil
        @vibe_last_macro = nil
        @status = default_status
      end

      def initialize_copy(other)
        super
        @path = other.path.dup
        @original_content = other.original_content.dup
        @file_marker = EditorFileMarker.new(path: @path, content: @original_content, new_file: other.new_file)
        @original_digest = other.original_digest.dup
        @original_mtime = other.original_mtime
        @original_size = other.original_size
        @buffer = other.buffer.dup
        @status = other.status.dup
        @search_query = other.search_query.dup
        @search_direction = other.search_direction
        @kill_buffer = other.kill_buffer.dup
        @quit_confirmed = other.quit_confirmed
        @viewport_column = other.viewport_column
        @selection_anchor = other.selection_anchor
        @secondary_selections = other.selections.drop(1).map { |selection| selection.dup }
        @editor_mode = other.editor_mode.dup
        @emacs_pending = other.emacs_pending&.dup
        @kill_ring = other.kill_ring.map(&:dup)
        @last_yank_range = other.last_yank_range&.dup
        @last_yank_index = other.last_yank_index
        @vibe_mode = other.vibe_mode&.dup
        @vibe_pending = other.vibe_pending.dup
        @vibe_command = other.vibe_command.dup
        @undo_stack = other.undo_stack.map { |entry| { buffer: entry[:buffer].dup, cursor: entry[:cursor] } }
        @redo_stack = other.redo_stack.map { |entry| { buffer: entry[:buffer].dup, cursor: entry[:cursor] } }
        @vibe_last_change = other.vibe_last_change&.dup
        @vibe_last_find = other.vibe_last_find&.dup
        @vibe_last_visual_selection = other.vibe_last_visual_selection&.dup
        @vibe_visual_block_insert = other.vibe_visual_block_insert&.dup
        @vibe_marks = other.vibe_marks.transform_values(&:dup)
        @vibe_registers = other.vibe_registers.transform_values(&:dup)
        @vibe_macros = other.vibe_macros.transform_values(&:dup)
        @vibe_recording_macro = other.vibe_recording_macro
        @vibe_last_macro = other.vibe_last_macro
        @readonly = other.readonly
        @diff_view = other.diff_view
        invalidate_lines_cache
      end

      def buffer=(value)
        @buffer = value.to_s
        invalidate_lines_cache
      end

      def cursor
        @cursor
      end

      def cursor=(value)
        @cursor = clamp_offset(value)
      end

      def selection_anchor
        @selection_anchor
      end

      def selection_anchor=(value)
        @selection_anchor = value.nil? ? nil : clamp_offset(value)
      end

      def selections
        normalize_secondary_selections
        [primary_selection] + @secondary_selections.map(&:dup)
      end

      def multi_cursor?
        normalize_secondary_selections
        @secondary_selections.any?
      end

      def set_selections(values)
        first, *rest = values.to_a
        if first
          @selection_anchor = first[:anchor]
          @cursor = first[:cursor]
        else
          @selection_anchor = nil
          @cursor = 0
        end
        @secondary_selections = rest.map { |selection| normalized_selection(selection) }
        normalize_secondary_selections
      end

      def add_selection(anchor, cursor = anchor)
        @secondary_selections << normalized_selection(anchor: anchor, cursor: cursor)
        normalize_secondary_selections
      end

      def collapse_to_primary_selection
        @secondary_selections = []
        clear_selection
      end

      def secondary_cursor_offsets
        normalize_secondary_selections
        @secondary_selections.filter_map do |selection|
          selection[:cursor] if selection[:anchor] == selection[:cursor]
        end
      end

      def readonly?
        @readonly == true
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
        @lines_cache ||= begin
          values = @buffer.split("\n", -1)
          values.empty? ? [""] : values
        end
      end

      def cursor_line_and_column
        before_cursor = @buffer[0...@cursor].to_s
        [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
      end

      def set_cursor_line_and_column(line_index, column)
        @cursor = offset_for_line_and_column(line_index, column)
      end

      def offset_for_line_and_column(line_index, column)
        values = lines
        line_index = [[line_index.to_i, 0].max, values.length - 1].min
        column = [[column.to_i, 0].max, values[line_index].length].min
        values.first(line_index).sum { |line| line.length + 1 } + column
      end

      def push_undo
        @undo_stack << editor_snapshot
        @undo_stack.shift while @undo_stack.length > 100
        @redo_stack.clear
      end

      def undo
        snapshot = @undo_stack.pop
        unless snapshot
          @status = "Already at oldest change"
          return false
        end

        @redo_stack << editor_snapshot
        @redo_stack.shift while @redo_stack.length > 100
        restore_editor_snapshot(snapshot)
        changed!(clear_selections: false)
        @status = "Undo"
        true
      end

      def redo
        snapshot = @redo_stack.pop
        unless snapshot
          @status = "Already at newest change"
          return false
        end

        @undo_stack << editor_snapshot
        @undo_stack.shift while @undo_stack.length > 100
        restore_editor_snapshot(snapshot)
        changed!(clear_selections: false)
        @status = "Redo"
        true
      end

      def insert(text)
        text = text.to_s
        return if text.empty?
        return replace_selections(text) if multi_cursor?

        @buffer = @buffer[0...@cursor].to_s + text + @buffer[@cursor..].to_s
        @cursor += text.length
        changed!
      end

      def delete_before_cursor
        return delete_before_selections if multi_cursor?
        return false if @cursor.zero?

        @buffer = @buffer[0...(@cursor - 1)].to_s + @buffer[@cursor..].to_s
        @cursor -= 1
        changed!
        true
      end

      def delete_at_cursor
        return delete_at_selections if multi_cursor?
        return false unless @cursor < @buffer.length

        @buffer = @buffer[0...@cursor].to_s + @buffer[(@cursor + 1)..].to_s
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
        text = text.to_s
        return false if text.empty?

        @kill_buffer = text
        @kill_ring.unshift(text)
        @kill_ring.uniq!
        @kill_ring = @kill_ring.first(30)
        @last_yank_range = nil
        @last_yank_index = nil
        true
      end

      def yank_from_kill_ring
        text = @kill_ring.first.to_s
        return false if text.empty?

        start_index = @cursor
        insert(text)
        @last_yank_range = [start_index, @cursor]
        @last_yank_index = 0
        true
      end

      def yank_pop
        return false unless @last_yank_range && @last_yank_index
        return false if @kill_ring.length < 2

        @last_yank_index = (@last_yank_index + 1) % @kill_ring.length
        text = @kill_ring[@last_yank_index]
        start_index, end_index = @last_yank_range
        replace_range(start_index, end_index, text)
        @cursor = start_index + text.length
        @last_yank_range = [start_index, @cursor]
        true
      end

      def begin_selection
        @selection_anchor = @cursor
        @status = "Selection started"
      end

      def clear_selection
        @selection_anchor = nil
        @secondary_selections = []
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
        start_index, end_index = [start_index, end_index].minmax
        start_index = [[start_index, 0].max, @buffer.length].min
        end_index = [[end_index, 0].max, @buffer.length].min
        @buffer = @buffer[0...start_index].to_s + text.to_s + @buffer[end_index..].to_s
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
        @kill_buffer = @buffer[start_index...end_index].to_s
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
          @selection_anchor = range[0]
          @cursor = range[1]
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
        @search_active = true
        @search_direction = direction
        @search_query = +""
        @status = search_status_prefix
      end

      def cancel_search
        @search_active = false
        @status = "Search cancelled"
      end

      def append_search(text)
        @search_query << text.to_s
        @status = "#{search_status_prefix} #{@search_query}"
      end

      def delete_search_character
        @search_query = @search_query[0...-1].to_s
        @status = "#{search_status_prefix} #{@search_query}"
      end

      def confirm_search
        query = @search_query.to_s
        @search_active = false
        if query.empty?
          @status = "Search cancelled"
          return false
        end

        repeat_search(@search_direction, query)
      end

      def repeat_search(direction = @search_direction, query = @search_query)
        query = query.to_s
        if query.empty?
          @status = "No previous search"
          return false
        end

        @search_query = query
        @search_direction = direction
        index = if direction == :backward
          search_from = @cursor.positive? ? @cursor - 1 : @buffer.length
          @buffer.rindex(query, search_from) || @buffer.rindex(query)
        else
          @buffer.index(query, @cursor + 1) || @buffer.index(query)
        end
        if index
          @cursor = index
          @status = "Found: #{query}"
          true
        else
          @status = "No match: #{query}"
          false
        end
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
        @file_marker.changed_on_disk?(new_file: new_file)
      end

      private

      def invalidate_lines_cache
        @lines_cache = nil
      end

      def clamp_offset(value)
        [[value.to_i, 0].max, @buffer.length].min
      end

      def primary_selection
        { anchor: @selection_anchor || @cursor, cursor: @cursor }
      end

      def primary_selection_active?
        return false if @selection_anchor.nil?
        return true if vibe? && %w[visual visual_line visual_block].include?(@vibe_mode)

        @selection_anchor != @cursor
      end

      def normalized_selection(selection)
        {
          anchor: clamp_offset(selection[:anchor]),
          cursor: clamp_offset(selection[:cursor])
        }
      end

      def normalize_secondary_selections
        @secondary_selections ||= []
        seen = { [primary_selection[:anchor], primary_selection[:cursor]] => true }
        @secondary_selections = @secondary_selections.filter_map do |selection|
          normalized = normalized_selection(selection)
          key = [normalized[:anchor], normalized[:cursor]]
          next if seen[key]

          seen[key] = true
          normalized
        end
      end

      def selection_range_for(selection)
        [selection[:anchor], selection[:cursor]].minmax
      end

      def editor_snapshot
        { buffer: @buffer.dup, selections: selections }
      end

      def restore_editor_snapshot(snapshot)
        @buffer = snapshot[:buffer].to_s
        if snapshot[:selections]
          set_selections(snapshot[:selections])
        else
          @cursor = [snapshot[:cursor].to_i, @buffer.length].min
          @selection_anchor = nil
          @secondary_selections = []
        end
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
          @buffer = @buffer[0...edit[:start]].to_s + edit[:text] + @buffer[edit[:end]..].to_s
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
        @buffer = @buffer[0...start_index].to_s + @buffer[end_index..].to_s
        @cursor = start_index
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
        lines[line_index].to_s.index(/\S/) || 0
      end

      def empty_line?(line_index)
        lines[line_index].to_s.strip.empty?
      end

      def move_to_indentation_line(line_index, column)
        return if line_index.nil?

        set_cursor_line_and_column(line_index, column)
      end

      def next_indentation_line(current_line, current_indentation)
        end_line = lines.length - 1
        return nil if current_line == end_line

        next_line = current_line + 1
        jumping_over_space = indentation_level_for_line(next_line) != current_indentation || empty_line?(next_line)

        (next_line..end_line).each do |line_index|
          indentation = indentation_level_for_line(line_index)
          if jumping_over_space && indentation == current_indentation && !empty_line?(line_index)
            return line_index
          elsif !jumping_over_space && (indentation != current_indentation || empty_line?(line_index))
            return line_index - 1
          elsif !jumping_over_space && indentation == current_indentation && line_index == end_line
            return line_index
          end
        end

        nil
      end

      def previous_indentation_line(current_line, current_indentation)
        return nil if current_line.zero?

        previous_line = current_line - 1
        jumping_over_space = indentation_level_for_line(previous_line) != current_indentation || empty_line?(previous_line)

        previous_line.downto(0) do |line_index|
          indentation = indentation_level_for_line(line_index)
          if jumping_over_space && indentation == current_indentation && !empty_line?(line_index)
            return line_index
          elsif !jumping_over_space && (indentation != current_indentation || empty_line?(line_index))
            return line_index + 1
          elsif !jumping_over_space && indentation == current_indentation && line_index.zero?
            return line_index
          end
        end

        nil
      end

      def word_separator?(char)
        TextBoundary.word_separator?(char)
      end

      def search_status_prefix
        @search_direction == :backward ? "Search backward:" : "Search:"
      end

      def normalize_editor_mode(value)
        EditorMode.normalize(value)
      end

      def default_status
        return "Read-only diff · arrows/PageUp/PageDown move · Ctrl+F search · Ctrl+Q close" if readonly?

        case @editor_mode
        when "emacs"
          "C-x C-s save · C-x C-c quit · C-s search"
        when "vibe"
          "NORMAL · i insert · :w save · :q quit"
        else
          "Ctrl+S save · Ctrl+Q quit · Ctrl+F search · Ctrl+C copy"
        end
      end

      def changed!(clear_selections: true)
        invalidate_lines_cache
        @overwrite_confirmed = false
        @quit_confirmed = false
        if clear_selections
          @selection_anchor = nil
          @secondary_selections = []
        end
        @last_yank_range = nil
        @last_yank_index = nil
      end
    end
  end
end
