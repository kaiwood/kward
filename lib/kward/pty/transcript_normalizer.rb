require_relative "../terminal/ansi"
require_relative "../terminal/text"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Reduces safe, line-oriented PTY redraws to transcript-friendly text.
  class PtyTranscriptNormalizer
    HORIZONTAL_REDRAW_PATTERN = /[\r\b]|\e\[[0-9;]*[CDGK`]/.freeze

    MAX_SCREEN_COLUMNS = 4096

    def self.normalize(text, columns: 80, max_bytes: nil)
      columns = columns.to_i.clamp(1, MAX_SCREEN_COLUMNS)
      output = +""
      text.each_line do |line|
        body = line.delete_suffix("\n")
        output << if body.match?(HORIZONTAL_REDRAW_PATTERN)
          Line.new(body, columns).render
        else
          ANSI.sanitize_transcript(body)
        end
        output << "\n" if line.end_with?("\n")
        return nil if max_bytes && output.bytesize > max_bytes
      end
      output
    end

    # Applies the horizontal cursor controls accepted by AdaptivePtyOutputSink
    # without modeling a complete terminal screen.
    class Line
      WideGlyph = Struct.new(:text, :column, :width)

      def initialize(text, columns)
        @text = text
        @last_column = columns - 1
        @cells = []
        @cursor = 0
      end

      def render
        ANSI.scan_escape_tokens(@text).each do |token|
          token[:escape] ? apply_escape(token[:text]) : write_text(token[:text])
        end
        @cells.each_with_index.map do |cell, column|
          cell.is_a?(WideGlyph) ? (cell.text if cell.column == column) : cell
        end.join.rstrip
      end

      private

      def apply_escape(sequence)
        final = sequence[-1]
        return set_column(sequence) if final == "G" || final == "`"
        return move_cursor(sequence, 1) if final == "C"
        return move_cursor(sequence, -1) if final == "D"
        return erase_line(sequence) if final == "K"
      end

      def set_column(sequence)
        @cursor = (parameter(sequence, default: 1) - 1).clamp(0, @last_column)
      end

      def move_cursor(sequence, direction)
        distance = [parameter(sequence, default: 1), 1].max
        @cursor = (@cursor + (distance * direction)).clamp(0, @last_column)
      end

      def erase_line(sequence)
        case parameter(sequence, default: 0)
        when 1
          0.upto([@cursor, @cells.length - 1].min) { |index| clear_cell(index) }
        when 2
          @cells.clear
        else
          if @cursor < @cells.length
            clear_cell(@cursor)
            @cells.slice!(@cursor..)
          end
        end
      end

      def parameter(sequence, default:)
        value = sequence[2...-1].to_s.split(";", 2).first.to_s
        value.empty? ? default : value.to_i
      end

      def write_text(text)
        text.each_grapheme_cluster do |grapheme|
          case grapheme
          when "\r"
            @cursor = 0
          when "\b"
            @cursor = [@cursor - 1, 0].max
          when "\t"
            @cursor = [((@cursor / 8) + 1) * 8, @last_column].min
          else
            write_grapheme(grapheme)
          end
        end
      end

      def write_grapheme(grapheme)
        width = grapheme.ascii_only? ? 1 : TerminalText.width(grapheme)
        if width.zero?
          previous = @cells[@cursor - 1] if @cursor.positive?
          if previous.is_a?(WideGlyph)
            previous.text << grapheme
          elsif previous
            @cells[@cursor - 1] = previous + grapheme
          end
          return
        end

        fill_to_cursor
        width.times { |offset| clear_cell(@cursor + offset) }
        cell = width == 1 ? grapheme : WideGlyph.new(grapheme, @cursor, width)
        @cells.fill(cell, @cursor, width)
        @cursor += width
      end

      def clear_cell(column)
        cell = @cells[column]
        if cell.is_a?(WideGlyph)
          @cells.fill(" ", cell.column, cell.width)
        elsif cell
          @cells[column] = " "
        end
      end

      def fill_to_cursor
        @cells.concat([" "] * (@cursor - @cells.length)) if @cursor > @cells.length
      end
    end
  end
end
