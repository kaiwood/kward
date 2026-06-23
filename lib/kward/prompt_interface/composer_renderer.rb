# Namespace for the Kward CLI agent runtime.
module Kward
  # Renderer for the editable composer text area.
  class PromptInterface
    # Renderer for the editable prompt composer area.
    module ComposerRenderer
      private

      def composer_layout(width, height = screen_height)
        return editor_layout(width, height) if editor_active?
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

      def editor_layout(width, height = screen_height)
        content_width = [width - 4, 1].max
        bottom_rows = @tabs.empty? ? [bottom_border(width)] : tab_border_rows(width)
        visible_count = [[height - 3 - bottom_rows.length, 1].max, 1].max
        visible_count = [visible_count, height - 4].min if height > 4
        visible_count = [visible_count, 1].max
        line_index, column = @editor_state.cursor_line_and_column
        @editor_state.viewport_row = [[@editor_state.viewport_row, line_index - visible_count + 1].max, line_index].min
        @editor_state.viewport_row = [@editor_state.viewport_row, 0].max
        editor_lines = @editor_state.lines
        visible_lines = editor_lines[@editor_state.viewport_row, visible_count] || []
        actual_visible_count = visible_lines.length
        visible_lines << "" while visible_lines.length < visible_count
        gutter_width = editor_line_number_gutter_width
        text_width = [content_width - gutter_width, 1].max
        rows = [editor_top_border(width)]
        rows.concat(visible_lines.each_with_index.map do |line, index|
          gutter = if index < actual_visible_count
                     editor_line_number_gutter(@editor_state.viewport_row + index)
                   else
                     editor_blank_line_number_gutter
                   end
          rendered_line = editor_render_line(line, @editor_state.viewport_row + index, text_width)
          row = gutter + rendered_line
          box_content_row(row, content_width)
        end)
        rows << footer_row(content_width, editor_status_text)
        rows.concat(bottom_rows)
        cursor_row = 1 + line_index - @editor_state.viewport_row
        cursor_col = 2 + gutter_width + [column, text_width - 1].min
        [rows, cursor_row, cursor_col]
      end

      def editor_render_line(line, line_index, text_width)
        visible = visible_truncate(line, text_width)
        range = @editor_state.selection_range
        return visible unless range

        line_start = @editor_state.line_start_offset(line_index)
        selection_start = [range[0] - line_start, 0].max
        selection_end = [range[1] - line_start, visible.length].min
        return visible unless selection_start < selection_end

        visible[0...selection_start].to_s + colored(visible[selection_start...selection_end].to_s, 7) + visible[selection_end..].to_s
      end

      def editor_line_number_gutter_width
        [[@editor_state.lines.length.to_s.length, 4].max + 3, 1].max
      end

      def editor_line_number_gutter(line_index)
        number = (line_index + 1).to_s.rjust(editor_line_number_gutter_width - 3)
        "#{number} │ "
      end

      def editor_blank_line_number_gutter
        " " * editor_line_number_gutter_width
      end

      def editor_top_border(width)
        title = visible_truncate("Edit #{editor_display_path}#{@editor_state.dirty? ? " *" : ""}", [width - 4, 1].max)
        plain_title = ANSI.strip(title)
        "#{colored("╭", :primary_green)} #{title} #{colored("─" * [width - plain_title.length - 4, 0].max, :primary_green)}#{colored("╮", :primary_green)}"
      end

      def editor_display_path
        Pathname.new(@editor_state.path).relative_path_from(Pathname.new(Dir.pwd)).to_s
      rescue StandardError
        @editor_state.path
      end

      def editor_status_text
        text = @editor_state.search_active ? "#{@editor_state.search_direction == :backward ? "Search backward" : "Search"}: #{@editor_state.search_query}" : @editor_state.status
        visible_truncate(text, [screen_width - 4, 1].max)
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
          width = ANSI.strip(text).length
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
        text.to_s.scan(/\e\[[0-9;:]*m|./m).each do |part|
          if part.start_with?("\e")
            index = visible_offset.positive? ? last_index : left
            row[index] = row[index].to_s + part if index&.between?(0, row.length - 1)
            next
          end

          index = left + visible_offset
          break if index >= row.length
          row[index] = row[index].to_s.sub(/\A /, "") + part unless index.negative?
          last_index = index
          visible_offset += 1
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
