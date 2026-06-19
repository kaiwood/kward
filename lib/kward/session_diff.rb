require "json"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Counts unified-diff additions and deletions for summaries.
  class SessionDiff
    def initialize(additions: 0, deletions: 0)
      @base_additions = additions.to_i
      @base_deletions = deletions.to_i
      @file_changes = Hash.new { |changes, path| changes[path] = { removed: [], added: [] } }
    end

    def additions
      @base_additions + @file_changes.values.sum { |changes| changes[:added].length }
    end

    def deletions
      @base_deletions + @file_changes.values.sum { |changes| changes[:removed].length }
    end

    def self.from_session_file(path)
      records = File.readlines(path, chomp: true).filter_map { |line| parse_record(line) }
      from_records(records)
    rescue Errno::ENOENT, Errno::EACCES
      new
    end

    def self.from_records(records)
      execution_records = records.select { |record| record["type"] == "tool_execution_end" }
      source_records = execution_records.empty? ? records : execution_records
      source_records.each_with_object(new) do |record, diff|
        if record["type"] == "tool_execution_end"
          next if record["isError"] || record.dig("result", "isError")

          diff.add_diff(record.dig("result", "diff"))
        elsif record["type"] == "message" && (record.dig("message", "role") == "tool" || record.dig("message", :role) == "tool")
          diff.add_tool_result(record.dig("message", "content") || record.dig("message", :content))
        end
      end
    end

    def self.count(diff)
      if (stats = truncated_diff_stats(diff))
        return stats
      elsif truncated_diff?(diff)
        return { additions: 0, deletions: 0 }
      end

      additions = 0
      deletions = 0
      removed = []
      added = []
      flush = lambda do
        common = common_line_count(removed, added)
        additions += added.length - common
        deletions += removed.length - common
        removed.clear
        added.clear
      end

      diff.to_s.each_line do |line|
        if line.start_with?("+") && !line.start_with?("+++")
          added << line[1..]
        elsif line.start_with?("-") && !line.start_with?("---")
          removed << line[1..]
        else
          flush.call
        end
      end
      flush.call
      { additions: additions, deletions: deletions }
    end

    def empty?
      additions.zero? && deletions.zero?
    end

    def add_tool_result(content)
      text = content.to_s
      return false if text.start_with?("Error:", "Declined:")

      add_diff(extract_unified_diff(text))
    end

    def add_diff(diff)
      if self.class.truncated_diff_stats(diff) || self.class.truncated_diff?(diff)
        counts = self.class.count(diff)
        return false if counts[:additions].zero? && counts[:deletions].zero?

        @base_additions += counts[:additions]
        @base_deletions += counts[:deletions]
        return true
      end

      changes = self.class.changed_lines_by_file(diff)
      return false if changes.empty?

      changes.each { |path, lines| apply_file_change(path, lines) }
      true
    end

    private

    def self.truncated_diff_stats(diff)
      match = diff.to_s.match(/^\.\.\. diff truncated to \d+ bytes; full diff stats: \+(\d+)\|-(\d+)\./)
      return nil unless match

      { additions: match[1].to_i, deletions: match[2].to_i }
    end

    def self.truncated_diff?(diff)
      diff.to_s.match?(/^\.\.\. diff truncated to \d+ bytes;/)
    end

    def self.common_line_count(left, right)
      previous = Array.new(right.length + 1, 0)
      left.each do |left_line|
        current = Array.new(right.length + 1, 0)
        right.each_with_index do |right_line, index|
          current[index + 1] = if left_line == right_line
                                 previous[index] + 1
                               else
                                 [current[index], previous[index + 1]].max
                               end
        end
        previous = current
      end
      previous.last
    end

    def self.changed_lines_by_file(diff)
      current_path = nil
      changes = Hash.new { |file_changes, path| file_changes[path] = { removed: [], added: [] } }
      removed = []
      added = []
      flush = lambda do
        unmatched = unmatched_lines(removed, added)
        changes[current_path][:removed].concat(unmatched[:removed]) if current_path
        changes[current_path][:added].concat(unmatched[:added]) if current_path
        removed.clear
        added.clear
      end

      diff.to_s.each_line do |line|
        if line.start_with?("--- ")
          flush.call
          current_path = line[4..].to_s.chomp
        elsif line.start_with?("+") && !line.start_with?("+++")
          added << line[1..]
        elsif line.start_with?("-") && !line.start_with?("---")
          removed << line[1..]
        else
          flush.call
        end
      end
      flush.call
      changes.reject { |_path, lines| lines[:removed].empty? && lines[:added].empty? }
    end

    def self.unmatched_lines(left, right)
      matches = common_line_indexes(left, right)
      left_matches = matches.map(&:first)
      right_matches = matches.map(&:last)
      {
        removed: left.each_index.reject { |index| left_matches.include?(index) }.map { |index| left[index] },
        added: right.each_index.reject { |index| right_matches.include?(index) }.map { |index| right[index] }
      }
    end

    def self.common_line_indexes(left, right)
      lengths = Array.new(left.length + 1) { Array.new(right.length + 1, 0) }
      left.each_with_index do |left_line, left_index|
        right.each_with_index do |right_line, right_index|
          lengths[left_index + 1][right_index + 1] = if left_line == right_line
                                                        lengths[left_index][right_index] + 1
                                                      else
                                                        [lengths[left_index + 1][right_index], lengths[left_index][right_index + 1]].max
                                                      end
        end
      end

      indexes = []
      left_index = left.length
      right_index = right.length
      while left_index.positive? && right_index.positive?
        if left[left_index - 1] == right[right_index - 1]
          indexes.unshift([left_index - 1, right_index - 1])
          left_index -= 1
          right_index -= 1
        elsif lengths[left_index - 1][right_index] >= lengths[left_index][right_index - 1]
          left_index -= 1
        else
          right_index -= 1
        end
      end
      indexes
    end

    def self.parse_record(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def apply_file_change(path, lines)
      remove_reverted_lines(@file_changes[path][:added], lines[:removed])
      remove_reverted_lines(@file_changes[path][:removed], lines[:added])
      @file_changes[path][:removed].concat(lines[:removed])
      @file_changes[path][:added].concat(lines[:added])
    end

    def remove_reverted_lines(previous_lines, current_lines)
      current_lines.delete_if do |line|
        index = previous_lines.index(line)
        previous_lines.delete_at(index) if index
      end
    end

    def extract_unified_diff(text)
      index = text.index(/^--- /)
      index ? text[index..] : nil
    end
  end
end
