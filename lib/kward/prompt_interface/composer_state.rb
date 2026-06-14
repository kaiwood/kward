module Kward
  class PromptInterface
    class ComposerState
      attr_accessor :input, :cursor, :kill_buffer, :history_index, :history_draft, :prefill_input
      attr_reader :attachments, :history

      def initialize
        @input = +""
        @cursor = 0
        @attachments = []
        @kill_buffer = ""
        @history = []
        @history_index = nil
        @history_draft = nil
        @prefill_input = nil
      end

      def insert_string(string)
        return if string.empty?

        @input = @input[0...@cursor] + string + @input[@cursor..]
        @cursor += string.length
      end

      def delete_before_cursor
        return false if @cursor.zero?

        @input = @input[0...(@cursor - 1)] + @input[@cursor..]
        @cursor -= 1
        true
      end

      def delete_at_cursor
        return false unless @cursor < @input.length

        @input = @input[0...@cursor] + @input[(@cursor + 1)..]
        true
      end

      def move_cursor_left
        @cursor -= 1 if @cursor.positive?
      end

      def move_cursor_right
        @cursor += 1 if @cursor < @input.length
      end

      def move_to_start_of_line
        @cursor = 0
      end

      def move_to_end_of_line
        @cursor = @input.length
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
        kill_range(0, @cursor)
      end

      def kill_line_after_cursor
        kill_range(@cursor, @input.length)
      end

      def kill_range(start_index, end_index)
        return false if start_index == end_index

        @kill_buffer = @input[start_index...end_index].to_s
        @input = @input[0...start_index].to_s + @input[end_index..].to_s
        @cursor = start_index
        true
      end

      def yank_kill_buffer
        insert_string(@kill_buffer.to_s) unless @kill_buffer.to_s.empty?
      end

      def previous_word_boundary(index)
        cursor = index
        cursor -= 1 while cursor.positive? && word_separator?(@input[cursor - 1])
        cursor -= 1 while cursor.positive? && !word_separator?(@input[cursor - 1])
        cursor
      end

      def next_word_boundary(index)
        cursor = index
        cursor += 1 while cursor < @input.length && word_separator?(@input[cursor])
        cursor += 1 while cursor < @input.length && !word_separator?(@input[cursor])
        cursor
      end

      def word_separator?(char)
        char.to_s.match?(/\s/)
      end

      def replace_input(value)
        @input = value.to_s
        @cursor = @input.length
      end

      def cursor_logical_position
        before_cursor = @input[0...@cursor]
        [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
      end
    end
  end
end
