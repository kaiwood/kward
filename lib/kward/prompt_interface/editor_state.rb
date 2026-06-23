require "digest"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Mutable state for the built-in composer file editor.
    class EditorState
      attr_reader :path, :original_content, :original_digest, :original_mtime, :original_size
      attr_accessor :buffer, :cursor, :viewport_row, :status, :overwrite_confirmed, :quit_confirmed, :search_active, :search_query, :new_file, :kill_buffer, :selection_anchor

      def initialize(path:, content:, new_file: false)
        @path = path.to_s
        @new_file = new_file
        @original_content = content.to_s
        @original_digest = Digest::SHA256.hexdigest(@original_content)
        refresh_file_marker unless new_file
        @buffer = @original_content.dup
        @cursor = 0
        @viewport_row = 0
        @status = "Ctrl+S save · Ctrl+Q quit · / search"
        @overwrite_confirmed = false
        @quit_confirmed = false
        @search_active = false
        @search_query = ""
        @kill_buffer = ""
        @selection_anchor = nil
      end

      def initialize_copy(other)
        super
        @path = other.path.dup
        @original_content = other.original_content.dup
        @original_digest = other.original_digest.dup
        @buffer = other.buffer.dup
        @status = other.status.dup
        @search_query = other.search_query.dup
        @kill_buffer = other.kill_buffer.dup
        @quit_confirmed = other.quit_confirmed
        @selection_anchor = other.selection_anchor
      end

      def dirty?
        @buffer != @original_content
      end

      def lines
        values = @buffer.split("\n", -1)
        values.empty? ? [""] : values
      end

      def cursor_line_and_column
        before_cursor = @buffer[0...@cursor].to_s
        [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
      end

      def set_cursor_line_and_column(line_index, column)
        values = lines
        line_index = [[line_index.to_i, 0].max, values.length - 1].min
        column = [[column.to_i, 0].max, values[line_index].length].min
        @cursor = values.first(line_index).sum { |line| line.length + 1 } + column
      end

      def insert(text)
        text = text.to_s
        return if text.empty?

        @buffer = @buffer[0...@cursor].to_s + text + @buffer[@cursor..].to_s
        @cursor += text.length
        changed!
      end

      def delete_before_cursor
        return false if @cursor.zero?

        @buffer = @buffer[0...(@cursor - 1)].to_s + @buffer[@cursor..].to_s
        @cursor -= 1
        changed!
        true
      end

      def delete_at_cursor
        return false unless @cursor < @buffer.length

        @buffer = @buffer[0...@cursor].to_s + @buffer[(@cursor + 1)..].to_s
        changed!
        true
      end

      def move_left
        @cursor -= 1 if @cursor.positive?
      end

      def move_right
        @cursor += 1 if @cursor < @buffer.length
      end

      def move_up
        line, column = cursor_line_and_column
        set_cursor_line_and_column(line - 1, column)
      end

      def move_down
        line, column = cursor_line_and_column
        set_cursor_line_and_column(line + 1, column)
      end

      def move_line_start
        line, = cursor_line_and_column
        set_cursor_line_and_column(line, 0)
      end

      def move_line_end
        line, = cursor_line_and_column
        set_cursor_line_and_column(line, lines[line].length)
      end

      def page_up(rows)
        line, column = cursor_line_and_column
        set_cursor_line_and_column(line - rows.to_i, column)
      end

      def page_down(rows)
        line, column = cursor_line_and_column
        set_cursor_line_and_column(line + rows.to_i, column)
      end

      def move_to_previous_word
        @cursor = previous_word_boundary(@cursor)
      end

      def move_to_next_word
        @cursor = next_word_boundary(@cursor)
      end

      def delete_word_before_cursor
        kill_range(previous_word_boundary(@cursor), @cursor)
      end

      def delete_word_after_cursor
        kill_range(@cursor, next_word_boundary(@cursor))
      end

      def kill_line_before_cursor
        kill_range(current_line_start, @cursor)
      end

      def kill_line_after_cursor
        if current_line_empty?
          kill_range(empty_line_start, empty_line_end)
        else
          kill_range(@cursor, current_line_end)
        end
      end

      def yank_kill_buffer
        insert(@kill_buffer.to_s) unless @kill_buffer.to_s.empty?
      end

      def begin_selection
        @selection_anchor = @cursor
        @status = "Selection started"
      end

      def clear_selection
        @selection_anchor = nil
      end

      def selection_active?
        !@selection_anchor.nil? && @selection_anchor != @cursor
      end

      def selection_range
        return nil unless selection_active?

        [@selection_anchor, @cursor].minmax
      end

      def selected_text
        range = selection_range
        return "" unless range

        @buffer[range[0]...range[1]].to_s
      end

      def line_start_offset(line_index)
        values = lines
        line_index = [[line_index.to_i, 0].max, values.length - 1].min
        values.first(line_index).sum { |line| line.length + 1 }
      end

      def begin_search
        @search_active = true
        @search_query = +""
        @status = "Search:"
      end

      def cancel_search
        @search_active = false
        @status = "Search cancelled"
      end

      def append_search(text)
        @search_query << text.to_s
        @status = "Search: #{@search_query}"
      end

      def delete_search_character
        @search_query = @search_query[0...-1].to_s
        @status = "Search: #{@search_query}"
      end

      def confirm_search
        query = @search_query.to_s
        @search_active = false
        if query.empty?
          @status = "Search cancelled"
          return false
        end

        index = @buffer.index(query, @cursor + 1) || @buffer.index(query)
        if index
          @cursor = index
          @status = "Found: #{query}"
          true
        else
          @status = "No match: #{query}"
          false
        end
      end

      def refresh_after_save(content)
        @new_file = false
        @original_content = content.to_s
        @original_digest = Digest::SHA256.hexdigest(@original_content)
        refresh_file_marker
        @overwrite_confirmed = false
        @quit_confirmed = false
        @status = "Saved #{@path}"
      end

      def file_changed_on_disk?
        return false if new_file && !File.exist?(@path)
        return true if new_file && File.exist?(@path)
        return true unless File.exist?(@path)

        File.read(@path) != @original_content
      rescue StandardError
        true
      end

      private

      def refresh_file_marker
        stat = File.stat(@path)
        @original_mtime = stat.mtime
        @original_size = stat.size
      rescue StandardError
        @original_mtime = nil
        @original_size = nil
      end

      def kill_range(start_index, end_index)
        return false if start_index == end_index

        @kill_buffer = @buffer[start_index...end_index].to_s
        @buffer = @buffer[0...start_index].to_s + @buffer[end_index..].to_s
        @cursor = start_index
        changed!
        true
      end

      def current_line_start
        @buffer.rindex("\n", @cursor - 1)&.+(1) || 0
      end

      def current_line_end
        @buffer.index("\n", @cursor) || @buffer.length
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
        cursor = index
        cursor -= 1 while cursor.positive? && word_separator?(@buffer[cursor - 1])
        cursor -= 1 while cursor.positive? && !word_separator?(@buffer[cursor - 1])
        cursor
      end

      def next_word_boundary(index)
        cursor = index
        cursor += 1 while cursor < @buffer.length && word_separator?(@buffer[cursor])
        cursor += 1 while cursor < @buffer.length && !word_separator?(@buffer[cursor])
        cursor
      end

      def word_separator?(char)
        char.to_s.match?(/\s/)
      end

      def changed!
        @overwrite_confirmed = false
        @quit_confirmed = false
        @selection_anchor = nil
      end
    end
  end
end
