require "unicode/display_width"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Terminal-cell and grapheme helpers for cursor-aware text layout.
  module TerminalText
    module_function

    def width(text)
      Unicode::DisplayWidth.of(text.to_s, ambiguous: 1, emoji: :all)
    end

    def truncate(text, max_width)
      string = text.to_s
      limit = [max_width.to_i, 0].max
      return string[0, limit].to_s if string.ascii_only?

      remaining = limit
      truncated = +""
      string.each_grapheme_cluster do |grapheme|
        grapheme_width = width(grapheme)
        break if grapheme_width > remaining

        truncated << grapheme
        remaining -= grapheme_width
      end
      truncated
    end

    def wrap(text, width:, cursor: nil)
      string = text.to_s
      line_width = [width.to_i, 1].max
      return wrap_ascii(string, line_width, cursor) if string.ascii_only?

      rows = [+""]
      row_widths = [0]
      cursor_row = nil
      cursor_col = nil
      offset = 0

      string.each_grapheme_cluster do |grapheme|
        if !cursor.nil? && cursor_row.nil? && cursor <= offset
          append_empty_row(rows, row_widths) if row_widths.last >= line_width
          cursor_row = rows.length - 1
          cursor_col = row_widths.last
        end

        grapheme_width = width(grapheme)
        append_empty_row(rows, row_widths) if row_widths.last.positive? && row_widths.last + grapheme_width > line_width
        rows.last << grapheme
        row_widths[-1] += grapheme_width
        offset += grapheme.length

        if !cursor.nil? && cursor_row.nil? && cursor <= offset
          cursor_row = rows.length - 1
          cursor_col = row_widths.last
        end
      end

      if !cursor.nil? && cursor_row.nil?
        append_empty_row(rows, row_widths) if row_widths.last >= line_width
        cursor_row = rows.length - 1
        cursor_col = row_widths.last
      elsif !cursor.nil? && cursor >= offset && row_widths.last >= line_width
        append_empty_row(rows, row_widths)
        cursor_row = rows.length - 1
        cursor_col = 0
      end

      { rows: rows, cursor_row: cursor_row, cursor_col: cursor_col }
    end

    def previous_grapheme_boundary(text, index)
      string = text.to_s
      cursor = [[index.to_i, 0].max, string.length].min
      return [cursor - 1, 0].max if string.ascii_only?

      previous = 0
      offset = 0
      string.each_grapheme_cluster do |grapheme|
        offset += grapheme.length
        return previous if offset >= cursor

        previous = offset
      end
      previous
    end

    def next_grapheme_boundary(text, index)
      string = text.to_s
      cursor = [[index.to_i, 0].max, string.length].min
      return [cursor + 1, string.length].min if string.ascii_only?

      offset = 0
      string.each_grapheme_cluster do |grapheme|
        offset += grapheme.length
        return offset if offset > cursor
      end
      string.length
    end

    def wrap_ascii(text, line_width, cursor)
      rows = text.scan(/.{1,#{line_width}}/m)
      rows = [""] if rows.empty?
      return { rows: rows, cursor_row: nil, cursor_col: nil } if cursor.nil?

      cursor = [[cursor.to_i, 0].max, text.length].min
      if cursor == text.length && text.length.positive? && (text.length % line_width).zero?
        rows << ""
      end
      { rows: rows, cursor_row: cursor / line_width, cursor_col: cursor % line_width }
    end
    private_class_method :wrap_ascii

    def append_empty_row(rows, row_widths)
      rows << +""
      row_widths << 0
    end
    private_class_method :append_empty_row
  end
end
