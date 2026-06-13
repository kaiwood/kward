require_relative "../ansi"
require_relative "../resources/avatar_kward_logo"
require_relative "../resources/pixel_logo"

module Kward
  class PromptInterface
    class Banner
      LOGO_WIDTH = 32
      LOGO_PIXEL_HEIGHT = 32
      MIN_LOGO_HEIGHT = 4
      LOGO_PIXELS = Kward::Resources::AvatarKwardLogo::PIXELS
      MESSAGE = "State your business.".freeze

      def initialize(message:, pixels:, screen_height:, minimum_composer_rows: 3)
        @message = message.to_s
        @pixels = pixels
        @screen_height = screen_height
        @minimum_composer_rows = minimum_composer_rows
        @logo_cache = {}
      end

      def rows(width)
        return [] unless visible?(width)

        rows = []
        rows.concat(centered_image_rows(width)) if image_visible?(width)
        rows << align_plain_row(@message, width) unless @message.empty?
        rows << ""
        rows
      end

      def logo_rows(width)
        logo_width, logo_height = logo_dimensions(width)
        return [] unless @pixels && max_logo_height >= MIN_LOGO_HEIGHT

        key = [logo_width, logo_height]
        @logo_cache[key] ||= Kward::PixelLogo.half_block_rows_from_pixels(@pixels, width: logo_width, pixel_height: logo_height)
      end

      private

      def visible?(width)
        !@message.empty? || image_visible?(width)
      end

      def image_visible?(width)
        !logo_rows(width).empty?
      end

      def centered_image_rows(width)
        logo_width, = logo_dimensions(width)
        padding = [[(width - logo_width) / 2, 0].max, width - 1].min
        logo_rows(width).map { |row| (" " * padding) + row }
      end

      def logo_dimensions(width)
        logo_width = [LOGO_WIDTH, [width - 2, 1].max].min
        logo_height = [LOGO_PIXEL_HEIGHT, max_logo_height * 2].min
        [logo_width, logo_height]
      end

      def max_logo_height
        message_rows = @message.empty? ? 0 : 1
        blank_after_banner = 1
        transcript_row = 1
        reserved_rows = message_rows + blank_after_banner + @minimum_composer_rows + transcript_row
        [@screen_height.call - reserved_rows, 0].max
      end

      def align_plain_row(text, width)
        plain_length = ANSI.strip(text).length
        padding = [width - plain_length, 0].max / 2
        (" " * padding) + text.to_s
      end
    end
  end
end
