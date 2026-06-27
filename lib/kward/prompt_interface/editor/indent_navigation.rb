# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Indentation-based navigation over editor lines.
    class EditorIndentNavigation
      def initialize(lines)
        @lines = lines
      end

      def indentation_level_for_line(line_index)
        @lines[line_index].to_s.index(/\S/) || 0
      end

      def empty_line?(line_index)
        @lines[line_index].to_s.strip.empty?
      end

      def next_line(current_line, current_indentation)
        end_line = @lines.length - 1
        return nil if current_line == end_line

        next_line = current_line + 1
        jumping_over_space = indentation_level_for_line(next_line) != current_indentation || empty_line?(next_line)

        (next_line..end_line).each do |line_index|
          indentation = indentation_level_for_line(line_index)
          if jumping_over_space && indentation == current_indentation && !empty_line?(line_index)
            return line_index
          elsif !jumping_over_space && (indentation != current_indentation || empty_line?(line_index))
            return line_index - 1
          elsif !jumping_over_space && indentation == current_indentation && line_index == end_line
            return line_index
          end
        end

        nil
      end

      def previous_line(current_line, current_indentation)
        return nil if current_line.zero?

        previous_line = current_line - 1
        jumping_over_space = indentation_level_for_line(previous_line) != current_indentation || empty_line?(previous_line)

        previous_line.downto(0) do |line_index|
          indentation = indentation_level_for_line(line_index)
          if jumping_over_space && indentation == current_indentation && !empty_line?(line_index)
            return line_index
          elsif !jumping_over_space && (indentation != current_indentation || empty_line?(line_index))
            return line_index + 1
          elsif !jumping_over_space && indentation == current_indentation && line_index.zero?
            return line_index
          end
        end

        nil
      end
    end
  end
end
