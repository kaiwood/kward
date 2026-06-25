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
        gutter_width = editor_line_number_gutter_width
        text_width = editor_text_width(content_width, gutter_width)
        sync_editor_wrap_state(text_width)

        if current_editor_soft_wrap?
          editor_wrapped_layout(width, content_width, visible_count, line_index, column, text_width)
        else
          editor_unwrapped_layout(width, content_width, visible_count, line_index, column, text_width)
        end
      end

      def editor_unwrapped_layout(width, content_width, visible_count, line_index, column, text_width)
        @editor_state.viewport_row = [[@editor_state.viewport_row, line_index - visible_count + 1].max, line_index].min
        @editor_state.viewport_row = [@editor_state.viewport_row, 0].max
        @editor_state.viewport_column = [[@editor_state.viewport_column.to_i, column - text_width + 1].max, column].min
        @editor_state.viewport_column = [@editor_state.viewport_column, 0].max
        editor_lines = @editor_state.lines
        visible_lines = editor_lines[@editor_state.viewport_row, visible_count] || []
        actual_visible_count = visible_lines.length
        visible_lines << "" while visible_lines.length < visible_count
        gutter_width = editor_line_number_gutter_width
        rows = [editor_top_border(width)]
        rows.concat(visible_lines.each_with_index.map do |line, index|
          gutter = if index < actual_visible_count
                     editor_line_number_gutter(@editor_state.viewport_row + index)
                   else
                     editor_blank_line_number_gutter
                   end
          rendered_line = editor_render_line(line, @editor_state.viewport_row + index, text_width, column_offset: @editor_state.viewport_column)
          row = gutter + rendered_line
          box_content_row(row, content_width)
        end)
        rows << footer_row(content_width, editor_status_text)
        rows.concat(editor_bottom_rows(width))
        cursor_row = 1 + line_index - @editor_state.viewport_row
        cursor_col = 2 + gutter_width + [[column - @editor_state.viewport_column, 0].max, text_width - 1].min
        [rows, cursor_row, cursor_col]
      end

      def editor_wrapped_layout(width, content_width, visible_count, line_index, column, text_width)
        visual_rows = editor_visual_rows(text_width)
        cursor_visual_row = editor_visual_row_for(line_index, column, text_width)
        @editor_state.viewport_row = [[@editor_state.viewport_row, cursor_visual_row - visible_count + 1].max, cursor_visual_row].min
        @editor_state.viewport_row = [@editor_state.viewport_row, 0].max
        visible_rows = visual_rows[@editor_state.viewport_row, visible_count] || []
        visible_rows << nil while visible_rows.length < visible_count
        rows = [editor_top_border(width)]
        rows.concat(visible_rows.map do |visual_row|
          if visual_row
            gutter = visual_row[:continuation] ? editor_blank_line_number_gutter : editor_line_number_gutter(visual_row[:line_index])
            rendered_line = editor_render_line(visual_row[:line], visual_row[:line_index], text_width, column_offset: visual_row[:column_offset])
            box_content_row(gutter + rendered_line, content_width)
          else
            box_content_row(editor_blank_line_number_gutter, content_width)
          end
        end)
        rows << footer_row(content_width, editor_status_text)
        rows.concat(editor_bottom_rows(width))
        line_start = editor_visual_row_start_column(line_index, column, text_width)
        cursor_row = 1 + cursor_visual_row - @editor_state.viewport_row
        cursor_col = 2 + editor_line_number_gutter_width + [[column - line_start, 0].max, text_width - 1].min
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

      def editor_render_line(line, line_index, text_width, column_offset: 0)
        visible = line.to_s[column_offset.to_i, text_width].to_s
        range = @editor_state.selection_range
        return editor_render_visible_line(visible, line_index) unless range

        line_start = @editor_state.line_start_offset(line_index)
        selection_start = [range[0] - line_start - column_offset.to_i, 0].max
        selection_end = [range[1] - line_start - column_offset.to_i, visible.length].min
        return editor_render_visible_line(visible, line_index) unless selection_start < selection_end

        visible[0...selection_start].to_s + colored(visible[selection_start...selection_end].to_s, 7) + visible[selection_end..].to_s
      end

      def editor_render_visible_line(line, line_index)
        return editor_render_diff_line(line) if @editor_state.diff_view?

        editor_highlight_line(line, line_index)
      end

      def editor_render_diff_line(line)
        text = line.to_s
        return colored(text, :green) if text.start_with?("+") && !text.start_with?("+++")
        return colored(text, :red) if text.start_with?("-") && !text.start_with?("---")
        return colored(text, :cyan) if text.start_with?("@@")

        text
      end

      def editor_line_number_gutter_width
        [[@editor_state.lines.length.to_s.length, 4].max + 3, 1].max
      end

      def editor_text_width(content_width, gutter_width = editor_line_number_gutter_width)
        [content_width - gutter_width, 1].max
      end

      def editor_visual_rows(text_width)
        @editor_state.lines.each_with_index.flat_map do |line, line_index|
          count = editor_visual_row_count(line, text_width)
          count.times.map do |index|
            column_offset = index * text_width
            { line_index: line_index, column_offset: column_offset, line: line, continuation: index.positive? }
          end
        end
      end

      def editor_visual_row_count(line, text_width)
        length = line.to_s.length
        return 1 if length.zero?

        ((length - 1) / text_width) + 1
      end

      def editor_visual_row_for(line_index, column, text_width)
        before = @editor_state.lines.first(line_index).sum { |line| editor_visual_row_count(line, text_width) }
        before + (editor_visual_row_start_column(line_index, column, text_width) / text_width)
      end

      def editor_visual_row_start_column(line_index, column, text_width)
        line = @editor_state.lines[line_index].to_s
        return 0 if column.to_i.zero?
        return column.to_i - text_width if column.to_i == line.length && (column.to_i % text_width).zero?

        (column.to_i / text_width) * text_width
      end

      def editor_line_number_gutter(line_index)
        number = editor_display_line_number(line_index).to_s.rjust(editor_line_number_gutter_width - 3)
        colored("#{number} │ ", :dark_forest_green)
      end

      def editor_display_line_number(line_index)
        return line_index + 1 unless current_editor_line_numbers == "relative"
        return line_index + 1 if @editor_state.readonly?

        cursor_line, = @editor_state.cursor_line_and_column
        line_index == cursor_line ? line_index + 1 : (line_index - cursor_line).abs
      end

      def editor_blank_line_number_gutter
        colored(" " * editor_line_number_gutter_width, :dark_forest_green)
      end

      def editor_top_border(width)
        title_prefix = @editor_state.diff_view? ? "Diff" : "Edit"
        dirty_marker = @editor_state.dirty? && !@editor_state.readonly? ? " *" : ""
        title = visible_truncate("#{title_prefix} #{editor_display_path}#{dirty_marker}", [width - 4, 1].max)
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
