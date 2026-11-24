module Kward
  class PromptInterface
    # Builds a unified comparison around the changed span of two buffers.
    module EditorBufferDiff
      module_function

      def compare(before, after, from:, to:)
        old_lines = before.to_s.lines
        new_lines = after.to_s.lines
        prefix = 0
        limit = [old_lines.size, new_lines.size].min
        prefix += 1 while prefix < limit && old_lines[prefix] == new_lines[prefix]
        suffix = 0
        suffix += 1 while suffix < limit - prefix && old_lines[-1 - suffix] == new_lines[-1 - suffix]
        start = [prefix - 3, 0].max
        old_change = old_lines[start...old_lines.size - suffix]
        new_change = new_lines[start...new_lines.size - suffix]
        tail = old_lines[old_lines.size - suffix, [suffix, 3].min]
        rows = ["--- #{from}", "+++ #{to}"]
        rows << "@@ -#{start + 1},#{old_change.size + tail.size} +#{start + 1},#{new_change.size + tail.size} @@"
        rows.concat(diff_rows(old_lines[start...prefix], " "))
        rows.concat(diff_rows(old_lines[prefix...old_lines.size - suffix], "-"))
        rows.concat(diff_rows(new_lines[prefix...new_lines.size - suffix], "+"))
        rows.concat(diff_rows(tail, " "))
        rows.join("\n")
      end

      def diff_rows(lines, marker)
        lines.flat_map do |line|
          text = ANSI.strip(line.chomp.scrub).gsub(/[\x00-\x08\x0b-\x1f\x7f]/, "�")
          line.end_with?("\n") ? [marker + text] : [marker + text, "\\ No newline at end of file"]
        end
      end
    end
  end
end
