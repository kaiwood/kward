# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Text storage and line/offset mechanics for editor buffers.
    class EditorBuffer
      attr_reader :text

      def initialize(text = "")
        @text = text.to_s
      end

      def text=(value)
        @text = value.to_s
        invalidate_lines_cache
      end

      def length
        @text.length
      end

      def empty?
        @text.empty?
      end

      def [](range)
        @text[range]
      end

      def slice(start_index, length = nil)
        length.nil? ? @text[start_index] : @text[start_index, length]
      end

      def before(offset)
        @text[0...offset].to_s
      end

      def after(offset)
        @text[offset..].to_s
      end

      def lines
        @lines_cache ||= begin
          values = @text.split("\n", -1)
          values.empty? ? [""] : values
        end
      end

      def line_and_column_for(offset)
        before_cursor = before(offset)
        [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
      end

      def offset_for_line_and_column(line_index, column)
        values = lines
        line_index = [[line_index.to_i, 0].max, values.length - 1].min
        column = [[column.to_i, 0].max, values[line_index].length].min
        values.first(line_index).sum { |line| line.length + 1 } + column
      end

      def line_start_offset(line_index)
        line_index = [[line_index.to_i, 0].max, lines.length - 1].min
        lines.first(line_index).sum { |line| line.length + 1 }
      end

      def line_range(line_index)
        start_index = line_start_offset(line_index)
        end_index = start_index + lines[line_index].to_s.length
        end_index += 1 if end_index < @text.length
        [start_index, end_index]
      end

      def replace_range(start_index, end_index, text)
        start_index, end_index = [start_index, end_index].minmax
        start_index = [[start_index, 0].max, @text.length].min
        end_index = [[end_index, 0].max, @text.length].min
        @text = @text[0...start_index].to_s + text.to_s + @text[end_index..].to_s
        invalidate_lines_cache
        [start_index, start_index + text.to_s.length]
      end

      def insert(offset, text)
        replace_range(offset, offset, text)
      end

      def delete_range(start_index, end_index)
        replace_range(start_index, end_index, "")
      end

      def index(*arguments)
        @text.index(*arguments)
      end

      def rindex(*arguments)
        @text.rindex(*arguments)
      end

      def count(*arguments)
        @text.count(*arguments)
      end

      private

      def invalidate_lines_cache
        @lines_cache = nil
      end
    end
  end
end
