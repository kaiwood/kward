# Namespace for the Kward CLI agent runtime.
module Kward
  # Deterministically trims large tool outputs before they are appended to the
  # model-facing transcript.
  #
  # The original output is still handed to session/tool-execution persistence by
  # ToolRegistry; this object only decides what the next model call sees. Keep it
  # conservative: small outputs and short errors are more valuable verbatim than
  # compacted.
  class ToolOutputCompactor
    MIN_BYTES = 12 * 1024
    ERROR_OUTPUT_MAX_BYTES = 8 * 1024
    HEAD_LINES = 40
    TAIL_LINES = 40
    ERROR_CONTEXT_LINES = 2

    ERROR_PATTERN = /\b(error|fatal|failed|failure|exception|traceback|panic|segmentation fault|assertion)\b/i.freeze

    def compact(tool_name, content)
      text = normalize(content)
      return text unless text.bytesize > MIN_BYTES
      return text if error_output?(text) && text.bytesize <= ERROR_OUTPUT_MAX_BYTES

      compacted = compact_lines(text)
      return text if compacted == text
      return text if compacted.bytesize >= text.bytesize

      header = compacted_header(tool_name, text, compacted)
      candidate = "#{header}\n\n#{compacted}"
      candidate.bytesize < text.bytesize ? candidate : text
    end

    private

    def normalize(content)
      return content unless content.is_a?(String)

      Conversation.normalize_tool_content(content)
    end

    def error_output?(text)
      text.match?(ERROR_PATTERN)
    end

    def compact_lines(text)
      lines = text.split("\n", -1)
      selected = selected_line_indexes(lines)
      return text if selected.length >= lines.length

      render_selected_lines(lines, selected)
    end

    def selected_line_indexes(lines)
      indexes = []
      indexes.concat((0...[HEAD_LINES, lines.length].min).to_a)
      indexes.concat(error_context_indexes(lines))

      tail_start = [lines.length - TAIL_LINES, 0].max
      indexes.concat((tail_start...lines.length).to_a)
      indexes.uniq.sort
    end

    def error_context_indexes(lines)
      indexes = []
      lines.each_with_index do |line, index|
        next unless line.match?(ERROR_PATTERN)

        first = [index - ERROR_CONTEXT_LINES, 0].max
        last = [index + ERROR_CONTEXT_LINES, lines.length - 1].min
        indexes.concat((first..last).to_a)
      end
      indexes
    end

    def render_selected_lines(lines, selected)
      output = []
      previous = nil
      selected.each do |index|
        if previous && index > previous + 1
          output << "[... omitted lines #{previous + 2}-#{index} ...]"
        end
        output << lines[index]
        previous = index
      end
      output.join("\n")
    end

    def compacted_header(tool_name, original, compacted)
      [
        "[Tool output compacted by Kward: #{original.bytesize} bytes -> #{compacted.bytesize} bytes]",
        "Tool: #{tool_name}",
        "Preserved first #{HEAD_LINES} lines, last #{TAIL_LINES} lines, and error/failure context.",
        "Full output is retained in session tool-execution records, outside model context."
      ].join("\n")
    end
  end
end
