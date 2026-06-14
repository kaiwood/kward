# Namespace for the Kward CLI agent runtime.
module Kward
  # Bounded text buffer for transcript rendering.
  class PromptInterface
    # Bounded in-memory transcript buffer used by the prompt interface.
    class TranscriptBuffer
      attr_reader :text

      def initialize(limit:)
        @limit = limit
        @text = +""
        @display_rows_cache_width = nil
        @display_rows_cache_banner_count = nil
        @display_rows_cache = nil
      end

      def to_s
        @text
      end

      def include?(*arguments)
        @text.include?(*arguments)
      end

      def empty?
        @text.empty?
      end

      def end_with?(*suffixes)
        @text.end_with?(*suffixes)
      end

      def clear
        @text = +""
        invalidate_display_rows_cache
      end

      def append(text)
        @text << ANSI.sanitize_transcript(text)
        @text = @text[-@limit, @limit] if @text.length > @limit
        invalidate_display_rows_cache
        @text
      end

      def viewport_text(row_count, width, visual_banner_count:, banner_rows:)
        viewport_rows(row_count, width, visual_banner_count: visual_banner_count, banner_rows: banner_rows).join("\n")
      end

      def viewport_rows(row_count, width, visual_banner_count:, banner_rows:)
        return [] unless row_count.positive?

        rows = display_rows(width, visual_banner_count: visual_banner_count, banner_rows: banner_rows).last(row_count)
        rows = ([""] * (row_count - rows.length)) + rows if rows.length < row_count
        rows
      end

      def display_rows(width, visual_banner_count:, banner_rows:)
        if @display_rows_cache_width == width && @display_rows_cache_banner_count == visual_banner_count && @display_rows_cache
          return @display_rows_cache
        end

        rows = []
        visual_banner_count.times { rows.concat(banner_rows.call(width)) }
        rows << "" if visual_banner_count.positive? && @text.empty?
        rows.concat(text_display_rows(width))
        @display_rows_cache_width = width
        @display_rows_cache_banner_count = visual_banner_count
        @display_rows_cache = rows
      end

      def text_display_rows(width)
        @text.split(/\r\n|\r|\n/, -1).flat_map do |line|
          chunks = ANSI.wrap_visible(line, width)
          chunks.empty? ? [""] : chunks
        end
      end

      def invalidate_display_rows_cache
        @display_rows_cache_width = nil
        @display_rows_cache_banner_count = nil
        @display_rows_cache = nil
      end
    end
  end
end
