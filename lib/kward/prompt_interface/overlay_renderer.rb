module Kward
  class PromptInterface
    module OverlayRenderer
      private

      def active_overlay_rows(width, height: screen_height)
        return question_overlay_rows(width) if @question_state
        return selection_overlay_rows(width, height: height) if @select_state

        slash_overlay_rows(width, height: height)
      end

      def overlay_card_rows(title, content_rows, width)
        card_width = overlay_card_width(width)
        inner_width = [card_width - 4, 1].max
        rows = [overlay_top_border(title, card_width)]
        rows.concat(content_rows.map { |row| overlay_content_row(row, inner_width) })
        rows << overlay_bottom_border(card_width)
        rows.map { |row| align_overlay_row(row, width) }
      end

      def overlay_card_width(width)
        return width if width < 32
        return width if @overlay_settings["width"] == "maximum"

        [[width - 4, 32].max, 96].min
      end

      def overlay_top_border(title, card_width)
        title = visible_truncate(title.to_s, [card_width - 4, 1].max)
        plain_length = ANSI.strip(title).length
        colored("╭", :primary_green) + " #{colored(title, :bright_accent_green, :bold)} " + colored("─" * [card_width - plain_length - 4, 0].max, :primary_green) + colored("╮", :primary_green)
      end

      def overlay_bottom_border(card_width)
        colored("╰#{"─" * [card_width - 2, 0].max}╯", :primary_green)
      end

      def overlay_content_row(row, inner_width)
        text = visible_truncate(row[:text], inner_width)
        text = colored(text, :bright_accent_green, :bold) if row[:selected]
        colored("│", :primary_green) + " " + visible_ljust(text, inner_width) + " " + colored("│", :primary_green)
      end

      def overlay_text_line(text, style = nil)
        rendered = case style
                   when :bold
                     colored(text.to_s, :bold)
                   when :muted
                     colored(text.to_s, :gray)
                   else
                     text.to_s
                   end
        { text: rendered }
      end

      def overlay_blank_line
        { text: "" }
      end

      def overlay_choice_line(text, selected: false)
        { text: "#{selected ? "›" : " "} #{text}", selected: selected }
      end

      def align_overlay_row(row, width)
        plain_length = ANSI.strip(row).length
        padding = [width - plain_length, 0].max
        left = overlay_left_padding(width, plain_length)
        right = padding - left
        (" " * left) + row + (" " * right)
      end

      def overlay_left_padding(width, row_width)
        padding = [width - row_width, 0].max
        case @overlay_settings["alignment"]
        when "left"
          0
        when "right"
          padding
        else
          padding / 2
        end
      end

      def normalize_overlay_settings(settings)
        values = { "alignment" => "center", "width" => "capped" }
        source = settings.is_a?(Hash) ? settings : {}
        alignment = (source[:alignment] || source["alignment"]).to_s
        width = (source[:width] || source["width"]).to_s
        values["alignment"] = alignment if %w[left center right].include?(alignment)
        values["width"] = width if %w[capped maximum].include?(width)
        values
      end

      def visible_ljust(text, width)
        text.to_s + (" " * [width - ANSI.strip(text.to_s).length, 0].max)
      end

      def visible_truncate(text, width)
        plain = ANSI.strip(text.to_s)
        return text.to_s if plain.length <= width

        plain[0, width]
      end

    end
  end
end
