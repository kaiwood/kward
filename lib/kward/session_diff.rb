require "json"

module Kward
  class SessionDiff
    attr_reader :additions, :deletions

    def initialize(additions: 0, deletions: 0)
      @additions = additions.to_i
      @deletions = deletions.to_i
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
      @additions.zero? && @deletions.zero?
    end

    def add_tool_result(content)
      text = content.to_s
      return false if text.start_with?("Error:", "Declined:")

      add_diff(extract_unified_diff(text))
    end

    def add_diff(diff)
      counts = self.class.count(diff)
      return false if counts[:additions].zero? && counts[:deletions].zero?

      @additions += counts[:additions]
      @deletions += counts[:deletions]
      true
    end

    private

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

    def self.parse_record(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def extract_unified_diff(text)
      index = text.index(/^--- /)
      index ? text[index..] : nil
    end
  end
end
