# Namespace for the Kward CLI agent runtime.
module Kward
  # Cursor/column state for streamed assistant blocks.
  class PromptInterface
    # State object for streamed assistant output blocks.
    class StreamState
      attr_reader :block, :col

      def initialize
        reset
      end

      def reset
        @block = nil
        @col = 0
        @pending_wrap = false
      end

      def start_block(label)
        @block = label
      end

      def finish_block
        @block = nil
      end

      def pending_wrap?
        @pending_wrap
      end

      def reset_position_from_rows(rows, width)
        last_length = rows.empty? ? 0 : ANSI.strip(rows.last).length
        if last_length >= width
          @col = 0
          @pending_wrap = true
        else
          @col = last_length
          @pending_wrap = false
        end
      end

      def clear_pending_wrap
        @col = 0
        @pending_wrap = false
      end

      def update_position(text, width:)
        ANSI.strip(text).each_char do |char|
          case char
          when "\n", "\r"
            @col = 0
            @pending_wrap = false
          else
            @pending_wrap = false
            @col += 1
            if @col >= width
              @col = 0
              @pending_wrap = true
            end
          end
        end
      end
    end
  end
end
