# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared overlay drawing helpers for prompt UI popups.
  class PromptInterface
    # Renderer for selection, slash-command, and question overlays.
    module OverlayRenderer
      private

      def active_overlay_rows(width, height: screen_height)
        return question_overlay_rows(width) if @question_state
        return selection_overlay_rows(width, height: height) if @select_state
        return git_overlay_rows(width, height: height) if @git_state
        return image_viewer_rows(width, height: height) if image_viewer_active?
        return project_browser_rows(width, height: height) if project_browser_visible?
        return completion_overlay_rows(width, height: height) if @completion_overlay
        return history_search_overlay_rows(width, height: height) if history_search_active?
        return file_overlay_rows(width, height: height) if file_overlay_visible?

        slash_overlay_rows(width, height: height)
      end

      def completion_overlay_rows(width, height: screen_height)
        candidates = @completion_overlay[:candidates]
        max_rows = max_overlay_list_rows(height)
        selected = @completion_overlay[:index].to_i
        start = centered_list_window_start(selected, candidates.length, max_rows)
        rows = (candidates[start, max_rows] || []).each_with_index.map do |candidate, offset|
          overlay_choice_line(candidate, selected: start + offset == selected)
        end
        overlay_card_rows("Completions", rows, width)
      end

      def history_search_overlay_rows(width, height: screen_height)
        matches = history_search_matches
        if matches.empty?
          return overlay_card_rows("History", [overlay_text_line("No matching history", :muted)], width)
        end

        max_rows = max_overlay_list_rows(height)
        selected = @composer.history_search_index
        start = centered_list_window_start(selected, matches.length, max_rows)
        rows = (matches[start, max_rows] || []).each_with_index.map do |value, offset|
          overlay_choice_line(value, selected: start + offset == selected)
        end
        overlay_card_rows("History", rows, width)
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
        colored("╭", :primary_green) + " #{colored(title, :primary_green, :bold)} " + colored("─" * [card_width - plain_length - 4, 0].max, :primary_green) + colored("╮", :primary_green)
      end

      def overlay_bottom_border(card_width)
        colored("╰#{"─" * [card_width - 2, 0].max}╯", :primary_green)
      end

      def overlay_content_row(row, inner_width)
        text = visible_truncate(row[:text], inner_width)
        text = colored(text, :primary_green, :bold) if row[:selected]
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

      def next_list_selection_index(index, count)
        return 0 if count <= 0

        [index + 1, count - 1].min
      end

      def previous_list_selection_index(index, count)
        return 0 if count <= 0

        [index - 1, 0].max
      end

      def centered_list_window_start(index, count, max_rows)
        return 0 if count <= max_rows

        last_start = count - max_rows
        middle_offset = max_rows / 2
        [[index - middle_offset, 0].max, last_start].min
      end

      def max_overlay_list_rows(height)
        [[height - 7, 1].max, 8].min
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
