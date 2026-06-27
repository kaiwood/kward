# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Primary and secondary selection/cursor storage for editor buffers.
    class EditorSelections
      attr_reader :anchor, :secondary

      def initialize(cursor:, buffer_length:, anchor: nil, secondary: [])
        @cursor = cursor
        @buffer_length = buffer_length
        @anchor = anchor.nil? ? nil : clamp_offset(anchor)
        @secondary = secondary.map { |selection| normalized_selection(selection) }
        normalize
      end

      def cursor=(value)
        @cursor = value
        normalize
      end

      def buffer_length=(value)
        @buffer_length = value.to_i
        @anchor = clamp_offset(@anchor) unless @anchor.nil?
        @secondary = @secondary.map { |selection| normalized_selection(selection) }
        normalize
      end

      def anchor=(value)
        @anchor = value.nil? ? nil : clamp_offset(value)
        normalize
      end

      def all
        normalize
        [primary] + @secondary.map(&:dup)
      end

      def multi_cursor?
        normalize
        @secondary.any?
      end

      def set(values)
        first, *rest = values.to_a
        if first
          @anchor = first[:anchor]
          @cursor = first[:cursor]
        else
          @anchor = nil
          @cursor = 0
        end
        @secondary = rest.map { |selection| normalized_selection(selection) }
        normalize
      end

      def add(anchor, cursor = anchor)
        @secondary << normalized_selection(anchor: anchor, cursor: cursor)
        normalize
      end

      def clear
        @anchor = nil
        @secondary = []
      end

      def collapse_to_primary
        @secondary = []
        @anchor = nil
      end

      def secondary_cursor_offsets
        normalize
        @secondary.filter_map do |selection|
          selection[:cursor] if selection[:anchor] == selection[:cursor]
        end
      end

      def primary
        { anchor: @anchor || @cursor, cursor: @cursor }
      end

      def primary_active?(vibe_visual: false)
        return false if @anchor.nil?
        return true if vibe_visual

        @anchor != @cursor
      end

      def range_for(selection)
        [selection[:anchor], selection[:cursor]].minmax
      end

      private

      def normalize
        seen = { [primary[:anchor], primary[:cursor]] => true }
        @secondary = @secondary.filter_map do |selection|
          normalized = normalized_selection(selection)
          key = [normalized[:anchor], normalized[:cursor]]
          next if seen[key]

          seen[key] = true
          normalized
        end
      end

      def normalized_selection(selection)
        {
          anchor: clamp_offset(selection[:anchor]),
          cursor: clamp_offset(selection[:cursor])
        }
      end

      def clamp_offset(value)
        [[value.to_i, 0].max, @buffer_length].min
      end
    end
  end
end
