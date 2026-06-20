# Namespace for the Kward CLI agent runtime.
module Kward
  # Startup banner message renderer.
  class PromptInterface
    # Startup banner rendering data and helpers for the prompt interface.
    class Banner
      MESSAGE = "State your business.".freeze

      def initialize(message:, screen_height:, minimum_composer_rows: 3)
        @message = message.to_s
        @screen_height = screen_height
        @minimum_composer_rows = minimum_composer_rows
      end

      def rows(width, message: nil)
        content = message.nil? ? @message : message.to_s
        return [] if content.empty? || max_banner_rows <= 0

        visible_lines(content) + [""]
      end

      def logo_rows(_width)
        []
      end

      private

      def visible_lines(content)
        lines = content.lines(chomp: true)
        return lines if lines.length <= max_banner_rows
        return [lines.last] if max_banner_rows == 1

        lines.first(max_banner_rows - 1) + [lines.last]
      end

      def max_banner_rows
        transcript_row = 1
        blank_after_banner = 1
        reserved_rows = blank_after_banner + @minimum_composer_rows + transcript_row
        [@screen_height.call - reserved_rows, 0].max
      end

    end
  end
end
