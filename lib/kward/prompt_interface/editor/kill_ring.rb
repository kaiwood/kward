# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Kill buffer, kill ring, and yank-pop bookkeeping for editor buffers.
    class EditorKillRing
      attr_reader :kill_buffer, :kill_ring, :last_yank_range, :last_yank_index

      def initialize(kill_buffer: "", kill_ring: [], last_yank_range: nil, last_yank_index: nil)
        @kill_buffer = kill_buffer.to_s
        @kill_ring = kill_ring
        @last_yank_range = last_yank_range
        @last_yank_index = last_yank_index
      end

      def kill_buffer=(text)
        @kill_buffer = text.to_s
        clear_last_yank
      end

      def kill_ring=(values)
        @kill_ring = values.to_a
      end

      def last_yank_range=(value)
        @last_yank_range = value
      end

      def last_yank_index=(value)
        @last_yank_index = value
      end

      def push(text)
        text = text.to_s
        return false if text.empty?

        @kill_buffer = text
        @kill_ring.unshift(text)
        @kill_ring.uniq!
        @kill_ring = @kill_ring.first(30)
        clear_last_yank
        true
      end

      def first_yank
        text = @kill_ring.first.to_s
        return nil if text.empty?

        text
      end

      def record_yank(start_index, end_index)
        @last_yank_range = [start_index, end_index]
        @last_yank_index = 0
      end

      def next_yank_pop
        return nil unless @last_yank_range && @last_yank_index
        return nil if @kill_ring.length < 2

        @last_yank_index = (@last_yank_index + 1) % @kill_ring.length
        {
          text: @kill_ring[@last_yank_index],
          range: @last_yank_range
        }
      end

      def record_yank_pop(start_index, end_index)
        @last_yank_range = [start_index, end_index]
      end

      def clear_last_yank
        @last_yank_range = nil
        @last_yank_index = nil
      end
    end
  end
end
