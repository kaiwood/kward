# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Renderer for the built-in composer file editor.
    module EditorRenderer
      private

      def editor_layout(width, height = screen_height)
        content_width = [width - 4, 1].max
        visible_count = editor_visible_line_count(height: height, width: width)
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
        rows.concat(editor_bottom_rows(width))
        cursor_row = 1 + line_index - @editor_state.viewport_row
        cursor_col = 2 + gutter_width + [column, text_width - 1].min
        [rows, cursor_row, cursor_col]
      end

      def editor_visible_line_count(height: screen_height, width: screen_width)
        visible_count = [[height - 3 - editor_bottom_rows(width).length, 1].max, 1].max
        visible_count = [visible_count, height - 4].min if height > 4
        [visible_count, 1].max
      end

      def editor_bottom_rows(width)
        @tabs.empty? ? [bottom_border(width)] : tab_border_rows(width)
      end

      def editor_render_line(line, line_index, text_width)
        visible = visible_truncate(line, text_width)
        range = @editor_state.selection_range
        return editor_highlight_line(visible) unless range

        line_start = @editor_state.line_start_offset(line_index)
        selection_start = [range[0] - line_start, 0].max
        selection_end = [range[1] - line_start, visible.length].min
        return editor_highlight_line(visible) unless selection_start < selection_end

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
    end
  end
end
