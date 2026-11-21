require_relative "../terminal/ansi"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Reduces safe, line-oriented PTY redraws to transcript-friendly text.
  class PtyTranscriptNormalizer
    HORIZONTAL_REDRAW_PATTERN = /\r|\e\[[0-9;]*[CDGK`]/.freeze

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
        @cells.join.rstrip
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
          0.upto([@cursor, @cells.length - 1].min) { |index| @cells[index] = " " }
        when 2
          @cells.clear
        else
          @cells.slice!(@cursor..) if @cursor < @cells.length
        end
      end

      def parameter(sequence, default:)
        value = sequence[2...-1].to_s.split(";", 2).first.to_s
        value.empty? ? default : value.to_i
      end

      def write_text(text)
        text.each_char do |character|
          case character
          when "\r"
            @cursor = 0
          when "\b"
            @cursor = [@cursor - 1, 0].max
          when "\t"
            @cursor = [((@cursor / 8) + 1) * 8, @last_column].min
          else
            fill_to_cursor
            @cells[@cursor] = character
            @cursor += 1
          end
        end
      end

      def fill_to_cursor
        @cells.concat([" "] * (@cursor - @cells.length)) if @cursor > @cells.length
      end
    end
  end
end
