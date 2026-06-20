# Namespace for the Kward CLI agent runtime.
module Kward
  # Renderer for the editable composer text area.
  class PromptInterface
    # Renderer for the editable prompt composer area.
    module ComposerRenderer
      private

      def composer_layout(width, height = screen_height)
        return compact_composer_layout(width) if height < 4
        return question_composer_layout(width, height) if @question_state

        content_width = [width - 4, 1].max
        input_layout_rows, input_cursor_row, input_cursor_col = input_layout(content_width)
        attachment_rows = attachment_badge_rows(content_width)
        overlay_rows = active_overlay_rows(width, height: height)
        footer_text = footer_text()
        max_input_rows = max_visible_input_rows(attachment_rows.length, overlay_rows.length, footer_text.empty? ? 0 : 1, height: height)
        visible_start = [[input_cursor_row - max_input_rows + 1, 0].max, [input_layout_rows.length - max_input_rows, 0].max].min
        visible_rows = input_layout_rows[visible_start, max_input_rows] || [""]
        rows = overlay_rows + [top_border(width)]
        rows.concat(attachment_rows)
        rows.concat(visible_rows.map { |row| box_content_row(row, content_width) })
        rows << footer_row(content_width, footer_text) unless footer_text.empty?
        rows << bottom_border(width)
        cursor_row = overlay_rows.length + 1 + attachment_rows.length + input_cursor_row - visible_start
        cursor_col = 2 + [input_cursor_col, content_width - 1].min
        [rows, cursor_row, cursor_col]
      end

      def compact_composer_layout(width)
        cursor_line, cursor_col = cursor_logical_position
        prefix = "#{@prompt_label} "
        line = input_lines[cursor_line] || ""
        input_width = [width - prefix.length, 1].max
        visible_start = [[cursor_col - input_width + 1, 0].max, [line.length - input_width, 0].max].min
        visible = line[visible_start, input_width].to_s
        row = "#{prefix}#{visible}"[0, width].to_s.ljust(width)
        [[row], 0, [prefix.length + cursor_col - visible_start, width - 1].min]
      end

      def input_layout(content_width)
        cursor_line, cursor_col = cursor_logical_position
        rows = []
        cursor_row = 0
        rendered_row_offset = 0

        input_lines.each_with_index do |line, index|
          prefix = input_prefix(index)
          continuation_prefix = " " * prefix.length
          available = [content_width - prefix.length, 1].max
          chunks = line.scan(/.{1,#{available}}/m)
          chunks = [""] if chunks.empty?
          if index == cursor_line && cursor_col == line.length && line.length.positive? && (line.length % available).zero?
            chunks << ""
          end

          if index == cursor_line
            cursor_row = rendered_row_offset + (cursor_col / available)
          end

          chunks.each_with_index do |chunk, chunk_index|
            rows << "#{chunk_index.zero? ? prefix : continuation_prefix}#{chunk}"
          end
          rendered_row_offset += chunks.length
        end

        prefix = input_prefix(cursor_line)
        available = [content_width - prefix.length, 1].max
        cursor_col_in_row = prefix.length + (cursor_col % available)
        [rows, cursor_row, cursor_col_in_row]
      end

      def top_border(width)
        title = composer_title
        status = composer_status_text
        if status
          gap = width - 2 - ANSI.strip(title).length - ANSI.strip(status).length
          if gap >= 0
            return colored("╭", :primary_green) + title + colored("─" * gap, :primary_green) + status + colored("╮", :primary_green)
          end
        end
        plain_title = ANSI.strip(title)
        "#{colored("╭", :primary_green)}#{title}#{colored("─" * [width - plain_title.length - 2, 0].max, :primary_green)}#{colored("╮", :primary_green)}"
      end

      def composer_title
        label = composer_title_label
        if @busy && @queued_count.positive?
          status_composer_text(busy_title("#{label} · #{@queued_count} queued"))
        elsif @busy && @steered_count.to_i.positive?
          status_composer_text(busy_title("#{label} · #{spinner_frame} steering"))
        elsif @busy
          status_composer_text(busy_title("#{label} · #{spinner_frame} #{@busy_activity}"))
        else
          status_composer_text(label)
        end
      end

      def composer_title_label
        return "Search" if @select_state && select_search_active?

        @prompt_label.delete_suffix(">")
      end

      def busy_title(text)
        @busy_help ? "#{text} · #{BUSY_HELP_TEXT}" : text
      end

      def composer_status_text
        text = @composer_status&.call.to_s
        return nil if text.empty?

        status_composer_text(text)
      end

      def status_composer_text(text)
        " #{text} "
      end

      def bottom_border(width)
        colored("╰#{"─" * [width - 2, 0].max}╯", :primary_green)
      end

      def box_content_row(row, content_width)
        "#{colored("│", :primary_green)} #{row[0, content_width].to_s.ljust(content_width)} #{colored("│", :primary_green)}"
      end

      def footer_row(content_width, text = footer_text)
        return nil if text.empty?

        box_content_row(visible_truncate(text, content_width), content_width)
      end

      def footer_text
        return "" unless @footer

        @footer.call.to_s.gsub(/\s+/, " ").strip
      rescue StandardError
        ""
      end

      def attachment_badge_rows(content_width)
        attachment_badge_texts.map { |text| box_content_row(visible_truncate(text, content_width), content_width) }
      end

      def attachment_badge_texts
        return [] unless @attachment_badges

        Array(@attachment_badges.call(composer_input, composer_attachments)).map(&:to_s).reject(&:empty?)
      rescue ArgumentError
        Array(@attachment_badges.call(composer_input)).map(&:to_s).reject(&:empty?)
      rescue StandardError
        []
      end

      def max_visible_input_rows(attachment_count = 0, overlay_count = active_overlay_rows(screen_width).length, footer_count = footer_text.to_s.empty? ? 0 : 1, height: screen_height)
        input_cap = [COMPOSER_MAX_INPUT_ROWS - attachment_count, 1].max
        [[input_cap, height - 3 - overlay_count - footer_count - attachment_count].min, 1].max
      end

      def input_lines
        lines = composer_input.split("\n", -1)
        lines.empty? ? [""] : lines
      end

      def input_prefix(_index)
        ""
      end

      def cursor_logical_position
        before_cursor = composer_input[0...composer_cursor]
        [before_cursor.count("\n"), (before_cursor.split("\n", -1).last || "").length]
      end

    end
  end
end
