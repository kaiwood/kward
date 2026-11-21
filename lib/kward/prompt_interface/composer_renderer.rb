require_relative "../terminal/text"

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
        return compact_composer_layout(width) if width < 5 || height < 4
        return question_composer_layout(width, height) if @question_state

        overlay_rows = active_overlay_rows(width, height: height)
        available_rows = composer_row_budget(height) - overlay_rows.length
        return compact_composer_layout(width, overlay_rows) if available_rows < 3

        content_width = width - 4
        # Reserve the borders and the draft's cursor row before adding optional chrome.
        extra_rows = available_rows - 3
        attachment_rows = attachment_badge_rows(content_width).first(extra_rows)
        extra_rows -= attachment_rows.length
        footer = footer_row(content_width) if extra_rows.positive?
        extra_rows -= 1 if footer
        bottom_rows = composer_bottom_rows(width, 1 + extra_rows)
        input_cap = [COMPOSER_MAX_INPUT_ROWS - attachment_rows.length, 1].max
        max_input_rows = [input_cap, 2 + extra_rows - bottom_rows.length].min
        input_rows, cursor_row, cursor_col = visible_composer_input(content_width, max_input_rows)

        rows = overlay_rows + [top_border(width)] + attachment_rows + input_rows
        rows << footer if footer
        rows.concat(bottom_rows)
        [rows, overlay_rows.length + 1 + attachment_rows.length + cursor_row, cursor_col]
      end

      def compact_composer_layout(width, overlay_rows = [])
        lines, cursor_line, cursor_col = @composer.lines_and_cursor
        prefix = "#{@prompt_label} "
        prefix_width = TerminalText.width(prefix)
        prefix, prefix_width = "", 0 if prefix_width >= width
        line = lines[cursor_line] || ""
        input_width = [width - prefix_width, 1].max
        layout = TerminalText.wrap(line, width: input_width, cursor: cursor_col)
        visible = layout[:rows][layout[:cursor_row]].to_s
        row = visible_ljust(TerminalText.truncate("#{prefix}#{visible}", width), width)
        [overlay_rows + [row], overlay_rows.length, [prefix_width + layout[:cursor_col], width - 1].min]
      end

      def visible_composer_input(content_width, max_rows)
        rows, cursor_row, cursor_col = input_layout(content_width)
        start = [[cursor_row - max_rows + 1, 0].max, [rows.length - max_rows, 0].max].min
        visible = rows[start, max_rows].map { |row| box_content_row(row, content_width) }
        [visible, cursor_row - start, 2 + [cursor_col, content_width - 1].min]
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
        title = composer_title(width - 2)
        gap = width - 2 - TerminalText.width(ANSI.strip(title))
        status = cached_composer_status_text
        if status
          status_width = TerminalText.width(ANSI.strip(status))
          if status_width <= gap
            gap -= status_width
          else
            status = nil
          end
        end
        "#{colored("╭", :primary_green)}#{title}#{colored("─" * gap, :primary_green)}#{status}#{colored("╮", :primary_green)}"
      end

      def composer_title(max_width = nil)
        label = composer_title_label
        text = if @busy && @busy_activity_visible
          busy_composer_title(label, max_width)
        elsif @completion_status
          completion = colored(@completion_status[:text], @completion_status[:style], :bold)
          "#{label} · #{completion}"
        else
          label
        end
        title = status_composer_text(text)
        max_width ? visible_truncate(title, max_width) : title
      end

      def busy_composer_title(label, max_width)
        if @busy_activity == "Generating image…"
          track = Array.new(7, "░")
          track[@spinner_frame_index % track.length] = "█"
          elapsed = formatted_elapsed(monotonic_now - (@image_generation_started_at || @busy_started_at || monotonic_now))
          return busy_title("#{label} · #{colored(track.join, :activity)} #{@busy_activity}", max_width, elapsed: elapsed)
        end

        activity = if @queued_count.positive?
          colored("#{@queued_count} queued", :metadata)
        elsif @steered_count.to_i.positive?
          "#{colored(spinner_frame, :activity, :bold)} steering"
        elsif response_arriving?
          "#{colored("✦", :activity, :bold)} responding"
        else
          "#{colored(spinner_frame, :activity, :bold)} #{@busy_activity}"
        end
        busy_title("#{label} · #{activity}", max_width)
      end

      def composer_title_label
        return "Search" if @select_state && select_search_active?

        @prompt_label.delete_suffix(">")
      end

      def busy_title(text, max_width, elapsed: busy_elapsed_text)
        suffixes = []
        suffixes << colored(elapsed, :metadata) if elapsed
        suffixes << BUSY_HELP_TEXT if @busy_help
        suffixes.each do |suffix|
          expanded = "#{text} · #{suffix}"
          break if max_width && TerminalText.width(ANSI.strip(expanded)) + 2 > max_width

          text = expanded
        end
        text
      end

      def status_composer_text(text)
        " #{text} "
      end

      def bottom_border(width)
        colored("╰#{"─" * [width - 2, 0].max}╯", :primary_green)
      end

      def tab_border_rows(width)
        return [bottom_border(width)] if width < 10

        slots = visible_tab_slots(width, tab_slots(width))
        active_slot = slots.find { |slot| slot[:index] == @active_tab_index }
        return [bottom_border(width)] unless active_slot

        [
          color_tab_border(bottom_tab_border_row(width, active_slot)),
          color_tab_border(tab_bar_row(width, slots, active_slot)),
          color_tab_border(active_tab_bottom_row(width, active_slot))
        ]
      end

      def tab_slots(terminal_width)
        @tabs.each_with_index.map do |label, index|
          text = tab_label(label, index, max_width: [terminal_width - 10, 1].max)
          label_width = TerminalText.width(ANSI.strip(text))
          {
            index: index,
            label: text,
            label_width: label_width,
            inner_width: label_width + 2,
            width: label_width + 4
          }
        end
      end

      def visible_tab_slots(width, slots)
        active_index = @active_tab_index
        return [] unless slots[active_index]

        first = last = active_index
        return [] if tab_window_width(slots, first, last) > width

        loop do
          candidates = [first.positive? ? first - 1 : nil, last < slots.length - 1 ? last + 1 : nil].compact
          fitting = candidates.select do |index|
            candidate_first = [first, index].min
            candidate_last = [last, index].max
            tab_window_width(slots, candidate_first, candidate_last) <= width
          end
          break if fitting.empty?

          candidate = fitting.min_by { |index| (index - active_index).abs }
          first = [first, candidate].min
          last = [last, candidate].max
        end

        label_left = 4 + (first.positive? ? 1 : 0)
        slots[first..last].map do |slot|
          slot.merge(left: label_left - 2, label_left: label_left).tap do
            label_left += slot[:label_width] + 3
          end
        end
      end

      def tab_window_width(slots, first, last)
        label_width = slots[first..last].sum { |slot| slot[:label_width] }
        gaps = (last - first) * 3
        left_indicator = first.positive? ? 1 : 0
        right_indicator = last < slots.length - 1 ? 3 : 0
        6 + label_width + gaps + left_indicator + right_indicator
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
        place_string(row, 2, "‹") if slots.first[:index].positive?
        place_string(row, width - 3, "›") if slots.last[:index] < @tabs.length - 1
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

      def tab_label(label, index, max_width: nil)
        tab = normalize_tab_label(label)
        name = tab[:name].empty? ? "Tab" : tab[:name]
        if max_width
          name_width = [max_width - TerminalText.width("#{index + 1} "), 1].max
          name = TerminalText.truncate(name, name_width)
        end
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

      def composer_bottom_rows(width, max_rows)
        return [bottom_border(width)] if @tabs.empty? || max_rows < 3

        tab_border_rows(width)
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
        state = @image_viewer_state
        title = "Image: #{state[:display_path]}"
        footer_rows = if state[:generated]
          generated_image_footer_rows(content_width)
        else
          zoom = (image_viewer_zoom * 100).round
          [footer_row(content_width, "Read-only image preview · #{zoom}% · +/- zoom · Esc/Q close")]
        end
        preview_budget = composer_overlay_row_budget(height) - 2 - footer_rows.length
        if preview_budget < (state[:directory_picker] ? 0 : 1)
          message = overlay_text_line("Pane too short for image preview · Esc back", :muted)
          return overlay_card_rows(title, [message], width, height: height)
        end

        rows = [overlay_top_border(title, width)]
        if state[:directory_picker]
          # The picker owns the overlay while active; don't draw under its input.
        elsif state[:preview_error]
          rows << box_content_row("Preview unavailable: #{state[:preview_error]}", content_width)
        else
          preview_rows = [image_viewer_preview_rows(height, width: width), preview_budget].min
          rows << image_viewer_graphic_row(width, image_viewer_sequence(width, preview_rows))
          rows.concat(Array.new(preview_rows - 1) { box_content_row("", content_width) })
        end
        rows.concat(footer_rows) << bottom_border(width)
      end

      def image_viewer_graphic_row(width, sequence)
        left_border = "#{colored("│", :primary_green)} "
        right_border = "#{TerminalSequences.move_to_column(width)}#{colored("│", :primary_green)}"
        "#{TTY::Cursor.clear_line}#{left_border}#{sequence}#{right_border}"
      end

    end
  end
end
