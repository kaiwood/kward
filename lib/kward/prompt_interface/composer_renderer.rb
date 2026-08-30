require_relative "../terminal_text"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Renderer for the editable composer text area.
  class PromptInterface
    # Renderer for the editable prompt composer area.
    module ComposerRenderer
      private

      def composer_layout(width, height = screen_height)
        return interactive_layout(width, height) if interactive_active_locked?
        return editor_layout(width, height) if editor_visible?
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
        if @tabs.empty?
          rows << bottom_border(width)
        else
          rows.concat(tab_border_rows(width))
        end
        cursor_row = overlay_rows.length + 1 + attachment_rows.length + input_cursor_row - visible_start
        cursor_col = 2 + [input_cursor_col, content_width - 1].min
        [rows, cursor_row, cursor_col]
      end

      def compact_composer_layout(width)
        lines, cursor_line, cursor_col = @composer.lines_and_cursor
        prefix = "#{@prompt_label} "
        prefix_width = TerminalText.width(prefix)
        line = lines[cursor_line] || ""
        input_width = [width - prefix_width, 1].max
        layout = TerminalText.wrap(line, width: input_width, cursor: cursor_col)
        visible = layout[:rows][layout[:cursor_row]].to_s
        row = visible_ljust(TerminalText.truncate("#{prefix}#{visible}", width), width)
        [[row], 0, [prefix_width + layout[:cursor_col], width - 1].min]
      end

      def input_layout(content_width)
        lines, cursor_line, cursor_col = @composer.lines_and_cursor
        rows = []
        cursor_row = 0
        cursor_col_in_row = 0
        rendered_row_offset = 0

        lines.each_with_index do |line, index|
          prefix = input_prefix(index)
          prefix_width = TerminalText.width(prefix)
          continuation_prefix = " " * prefix_width
          available = [content_width - prefix_width, 1].max
          layout = TerminalText.wrap(line, width: available, cursor: index == cursor_line ? cursor_col : nil)

          if index == cursor_line
            cursor_row = rendered_row_offset + layout[:cursor_row]
            cursor_col_in_row = prefix_width + layout[:cursor_col]
          end

          layout[:rows].each_with_index do |chunk, chunk_index|
            rows << "#{chunk_index.zero? ? prefix : continuation_prefix}#{chunk}"
          end
          rendered_row_offset += layout[:rows].length
        end

        [rows, cursor_row, cursor_col_in_row]
      end

      def top_border(width)
        title = composer_title
        status = cached_composer_status_text
        if status
          gap = width - 2 - TerminalText.width(ANSI.strip(title)) - TerminalText.width(ANSI.strip(status))
          if gap >= 0
            return colored("╭", :primary_green) + title + colored("─" * gap, :primary_green) + status + colored("╮", :primary_green)
          end
        end
        plain_title = ANSI.strip(title)
        "#{colored("╭", :primary_green)}#{title}#{colored("─" * [width - TerminalText.width(plain_title) - 2, 0].max, :primary_green)}#{colored("╮", :primary_green)}"
      end

      def composer_title
        label = composer_title_label
        if @busy && @queued_count.positive?
          status_composer_text(busy_title("#{label} · #{colored("#{@queued_count} queued", :metadata)}"))
        elsif @busy && @steered_count.to_i.positive?
          status_composer_text(busy_title("#{label} · #{colored(spinner_frame, :activity, :bold)} steering"))
        elsif @busy
          status_composer_text(busy_title("#{label} · #{colored(spinner_frame, :activity, :bold)} #{@busy_activity}"))
        elsif @completion_status
          completion = colored(@completion_status[:text], @completion_status[:style], :bold)
          status_composer_text("#{label} · #{completion}")
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

      def status_composer_text(text)
        " #{text} "
      end

      def bottom_border(width)
        colored("╰#{"─" * [width - 2, 0].max}╯", :primary_green)
      end

      def tab_border_rows(width)
        return [bottom_border(width)] if width < 10

        slots = tab_slots
        active_slot = slots[@active_tab_index]
        return [bottom_border(width)] unless active_slot
        return [bottom_border(width)] if active_slot[:left] + active_slot[:width] > width

        [
          color_tab_border(bottom_tab_border_row(width, active_slot)),
          color_tab_border(tab_bar_row(width, slots, active_slot)),
          color_tab_border(active_tab_bottom_row(width, active_slot))
        ]
      end

      def tab_slots
        label_left = 4
        @tabs.each_with_index.map do |label, index|
          text = tab_label(label, index)
          width = TerminalText.width(ANSI.strip(text))
          slot = {
            left: label_left - 2,
            label_left: label_left,
            label: text,
            inner_width: width + 2,
            width: width + 4
          }
          label_left += width + 3
          slot
        end
      end

      def bottom_tab_border_row(width, active_slot)
        row = Array.new(width, " ")
        place_string(row, 0, "╰#{"─" * [active_slot[:left] - 1, 0].max}╮")
        place_string(row, active_slot[:left] + active_slot[:inner_width] + 1, "╭")
        place_string(row, active_slot[:left] + active_slot[:inner_width] + 2, "─" * [width - active_slot[:left] - active_slot[:inner_width] - 3, 0].max)
        place_string(row, width - 1, "╯")
        row.join
      end

      def tab_bar_row(width, slots, active_slot)
        row = Array.new(width, " ")
        slots.each do |slot|
          if slot == active_slot
            place_string(row, slot[:left], "│ #{slot[:label]} │")
          else
            place_string(row, slot[:label_left], slot[:label])
          end
        end
        row.join
      end

      def active_tab_bottom_row(width, active_slot)
        row = Array.new(width, " ")
        place_string(row, active_slot[:left], "╰#{"─" * active_slot[:inner_width]}╯")
        row.join
      end

      def place_string(row, left, text)
        return if left >= row.length

        visible_offset = 0
        last_index = nil
        text.to_s.scan(/\e\[[0-9;:]*m|\X/m).each do |part|
          if part.start_with?("\e")
            index = visible_offset.positive? ? last_index : left
            row[index] = row[index].to_s + part if index&.between?(0, row.length - 1)
            next
          end

          part_width = TerminalText.width(part)
          if part_width.zero?
            row[last_index] = row[last_index].to_s + part if last_index
            next
          end

          index = left + visible_offset
          break if index >= row.length
          row[index] = row[index].to_s.sub(/\A /, "") + part unless index.negative?
          1.upto(part_width - 1) { |offset| row[index + offset] = "" if (index + offset).between?(0, row.length - 1) }
          last_index = index
          visible_offset += part_width
        end
      end

      def tab_label(label, index)
        tab = normalize_tab_label(label)
        name = tab[:name].empty? ? "Tab" : tab[:name]
        color = tab[:color]
        name = colored(name, color) if color
        "#{index + 1} #{name}"
      end

      def normalize_tab_label(label)
        return { name: label[:name].to_s, color: label[:color] } if label.is_a?(Hash)

        { name: label.to_s, color: nil }
      end

      def color_tab_border(row)
        row.gsub(/[╰╯╭╮│─]/) { |char| colored(char, :primary_green) }
      end

      def box_content_row(row, content_width)
        content = visible_ljust(visible_truncate(row, content_width), content_width)
        "#{colored("│", :primary_green)} #{content} #{colored("│", :primary_green)}"
      end

      def footer_row(content_width, text = footer_text)
        return nil if text.empty?

        box_content_row(visible_truncate(text, content_width), content_width)
      end

      def footer_text
        cached_footer_text
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

      def max_visible_input_rows(attachment_count, overlay_count, footer_count, height: screen_height)
        input_cap = [COMPOSER_MAX_INPUT_ROWS - attachment_count, 1].max
        [[input_cap, height - 3 - overlay_count - footer_count - attachment_count].min, 1].max
      end

      def input_prefix(_index)
        ""
      end

      def image_viewer_preview_rows(height, width: screen_width)
        available_rows = max_project_browser_rows(height, width: width)
        desired_rows = [(IMAGE_VIEWER_MAX_ROWS * image_viewer_zoom).round, 1].max
        [available_rows, desired_rows].min
      end

      def image_viewer_rows(width, height: screen_height)
        content_width = [width - 4, 1].max
        preview_rows = image_viewer_preview_rows(height, width: width)
        title = visible_truncate(" Image: #{@image_viewer_state[:display_path]} ", content_width)
        rows = [
          colored("╭", :primary_green) + title + colored("─" * [width - TerminalText.width(ANSI.strip(title)) - 2, 0].max, :primary_green) + colored("╮", :primary_green),
          image_viewer_graphic_row(width, image_viewer_sequence(width, height))
        ]
        rows.concat(Array.new(preview_rows - 1) { box_content_row("", content_width) })
        zoom = (image_viewer_zoom * 100).round
        rows << footer_row(content_width, "Read-only image preview · #{zoom}% · +/- zoom · Esc/Q close")
        rows << bottom_border(width)
        rows
      end

      def image_viewer_graphic_row(width, sequence)
        left_border = "#{colored("│", :primary_green)} "
        right_border = "#{TerminalSequences.move_to_column(width)}#{colored("│", :primary_green)}"
        "#{TTY::Cursor.clear_line}#{left_border}#{sequence}#{right_border}"
      end

    end
  end
end
