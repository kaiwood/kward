# Namespace for the Kward CLI agent runtime.
module Kward
  # Finds fenced Markdown code blocks and manages their adjacent output fields.
  class MarkdownCodeBlock
    Block = Struct.new(
      :source, :open_line, :close_line, :language, :body_start, :body_end, :close_end, :next_fence_start,
      keyword_init: true
    ) do
      def code
        source[body_start...body_end].to_s
      end

      def output_match
        limit = next_fence_start || source.length
        match = source.match(/<output\b[^>]*>.*?<\/output>/mi, close_end)
        match if match && match.begin(0) < limit && match.end(0) <= limit
      end

      def with_output(output)
        replacement = MarkdownCodeBlock.format_output(output, newline: newline)
        match = output_match
        if match
          source.dup.tap { |content| content[match.begin(0)...match.end(0)] = replacement }
        else
          insertion = if source[close_end - newline.length, newline.length] == newline
                         "#{newline}#{replacement}#{newline}"
                       else
                         "#{newline}#{newline}#{replacement}#{newline}"
                       end
          source.dup.tap { |content| content.insert(close_end, insertion) }
        end
      end

      private

      def newline
        source[body_end...close_end].to_s.end_with?("\r\n") ? "\r\n" : "\n"
      end
    end

    Fence = Struct.new(:line, :start, :finish, :marker, :length, :language, :close_line, :close_start, :close_end, keyword_init: true)

    class << self
      def for_selection(source, first_line, last_line)
        blocks = parse(source)
        candidates = blocks.select do |block|
          full_fence = first_line == block.open_line && last_line == block.close_line
          body_only = block.open_line < first_line && last_line < block.close_line
          full_fence || body_only
        end
        candidates.min_by { |block| block.close_line - block.open_line }
      end

      def for_cursor(source, line)
        parse(source).select do |block|
          block.open_line <= line && line <= block.close_line
        end.min_by { |block| block.close_line - block.open_line }
      end

      def parse(source)
        source = source.to_s
        lines = source.lines
        fences = []
        open_fences = []
        offset = 0

        lines.each_with_index do |line, line_number|
          content = line.chomp
          if (match = content.match(/\A\s*(`{3,}|~{3,})(.*)\z/))
            marker = match[1][0]
            length = match[1].length
            rest = match[2]
            closing = rest.match?(/\A\s*\z/)

            if closing && open_fences.last&.marker == marker && length >= open_fences.last.length
              opening = open_fences.pop
              fences << Fence.new(
                line: line_number,
                start: offset,
                finish: offset + line.length,
                marker: marker,
                length: length,
                language: opening.language
              )
              opening.close_line = line_number
              opening.close_start = offset
              opening.close_end = offset + line.length
              offset += line.length
              next
            end

            next if closing

            opening = Fence.new(
              line: line_number,
              start: offset,
              finish: offset + line.length,
              marker: marker,
              length: length,
              language: rest.strip.split(/\s+/, 2).first
            )
            open_fences << opening
            fences << opening
          end
          offset += line.length
        end

        completed = fences.select { |fence| fence.close_line }
        completed.map do |opening|
          next_fence = fences.map(&:start).select { |start| start > opening.close_end }.min
          Block.new(
            source: source,
            open_line: opening.line,
            close_line: opening.close_line,
            language: opening.language,
            body_start: opening.finish,
            body_end: opening.close_start,
            close_end: opening.close_end,
            next_fence_start: next_fence
          )
        end
      end

      def format_output(output, newline: "\n")
        body = output.to_s.gsub(/\r\n?/, "\n").chomp
        body = body.gsub("\n", newline)
        body.empty? ? "<output>#{newline}</output>" : "<output>#{newline}#{body}#{newline}</output>"
      end
    end
  end
end
