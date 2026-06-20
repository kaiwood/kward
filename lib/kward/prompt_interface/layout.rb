# Namespace for the Kward CLI agent runtime.
module Kward
  # Layout calculations for terminal rows and overlay placement.
  class PromptInterface
    # Terminal layout calculations for transcript, overlays, footer, and composer.
    module Layout
      private

      def banner_rows(width, message: nil)
        @banner.rows(width, message: message)
      end

      def banner_logo_rows
        @banner.logo_rows(screen_width)
      end

      def transcript_redraw_row_count(height = screen_height)
        [[@transcript_viewport_rows, transcript_bottom_row(height)].max, height].min
      end

      def composer_top_row(height = screen_height)
        [height - @reserved_rows + 1, 1].max
      end

      def transcript_bottom_row(height = screen_height)
        [height - @reserved_rows, 1].max
      end

    end
  end
end
