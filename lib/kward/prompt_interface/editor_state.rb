require "digest"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Mutable state for the built-in composer file editor.
    class EditorState
      attr_reader :path, :original_content, :original_digest, :original_mtime, :original_size
      attr_accessor :buffer, :cursor, :viewport_row, :status, :overwrite_confirmed, :search_active, :search_query, :new_file

      def initialize(path:, content:, new_file: false)
        @path = path.to_s
        @new_file = new_file
        @original_content = content.to_s
        @original_digest = Digest::SHA256.hexdigest(@original_content)
        refresh_file_marker unless new_file
        @buffer = @original_content.dup
        @cursor = 0
        @viewport_row = 0
        @status = "Ctrl+S save · Esc/Ctrl+C cancel · / search"
        @overwrite_confirmed = false
        @search_active = false
        @search_query = ""
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

      def changed!
        @overwrite_confirmed = false
      end
    end
  end
end
