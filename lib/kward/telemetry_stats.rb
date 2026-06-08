require "json"
require "time"
require_relative "config_files"
require_relative "telemetry_logger"

module Kward
  class TelemetryStats
    DEFAULT_RANGE = "1 week"
    UNITS = %w[minute hour day week month year].freeze
    USAGE = "Usage: /stats [N minutes|hours|days|weeks|months|years] (default: 1 week)".freeze
    TOKEN_CSV_HEADER = %w[bucket_start bucket_end provider model events input_tokens output_tokens cache_read_tokens cache_write_tokens total_tokens].freeze
    TOKEN_BUCKETS = %w[second minute hour day week month year].freeze

    Result = Struct.new(:range, :log_dir, :enabled_categories, :record_count, :records_by_category, :records_by_event, :tokens, :performance, :tools, :errors, keyword_init: true) do
      def to_h
        {
          range: {
            input: range[:input],
            count: range[:count],
            unit: range[:unit],
            startAt: range[:start_at].iso8601,
            endAt: range[:end_at].iso8601
          },
          logDir: log_dir,
          enabledCategories: enabled_categories,
          recordCount: record_count,
          recordsByCategory: records_by_category,
          recordsByEvent: records_by_event,
          usageStats: tokens,
          performance: performance,
          tools: tools,
          errors: errors
        }
      end
    end

    def initialize(telemetry_logger: TelemetryLogger.new, clock: Time)
      @telemetry_logger = telemetry_logger
      @clock = clock
    end

    def enabled_categories
      @telemetry_logger.enabled_categories
    end

    def log_dir
      @telemetry_logger.log_directory
    end

    def collect(argument = "")
      categories = enabled_categories
      raise ArgumentError, "Telemetry logging is disabled. Enable logging and at least one category before using /stats." if categories.empty?

      range = self.class.parse_range(argument, now: @clock.now.utc)
      records = read_records(range[:start_at], range[:end_at], categories)
      build_result(range, categories, records)
    end

    def token_usage_csv(argument = "", bucket: nil)
      categories = enabled_categories
      raise ArgumentError, "Token telemetry logging is disabled. Enable logging and token logging before exporting token CSV." unless categories.include?("tokens")

      range = self.class.parse_range(argument, now: @clock.now.utc)
      bucket = self.class.normalize_bucket(bucket || range[:unit])
      buckets = token_usage_buckets(range, bucket)
      lines = [csv_row(TOKEN_CSV_HEADER)]
      buckets.each do |_key, values|
        lines << csv_row(TOKEN_CSV_HEADER.map { |column| token_csv_value(values, column) })
      end
      lines.join("\n") + "\n"
    end

    def self.parse_range(argument, now: Time.now.utc)
      text = argument.to_s.strip
      text = DEFAULT_RANGE if text.empty?
      match = text.match(/\A(\d+)\s+([A-Za-z]+)\z/)
      raise ArgumentError, USAGE unless match

      count = match[1].to_i
      unit = normalize_unit(match[2])
      raise ArgumentError, USAGE unless count.positive? && unit

      {
        input: text,
        count: count,
        unit: unit,
        start_at: calendar_start(now.utc, count, unit),
        end_at: now.utc
      }
    end

    def self.format(result)
      lines = []
      range = result.range
      lines << "Stats for #{range[:input]} (#{range[:start_at].iso8601} to #{range[:end_at].iso8601})"
      lines << "Log directory: #{result.log_dir}"
      lines << "Enabled categories: #{result.enabled_categories.join(", ")}"
      lines << "Records: #{result.record_count}"
      lines << ""
      lines << "Records by category:"
      lines.concat(format_counts(result.records_by_category))
      lines << ""
      lines << "Records by event:"
      lines.concat(format_counts(result.records_by_event))
      lines << ""
      lines << "Tokens:"
      lines.concat(format_tokens(result.tokens))
      lines << ""
      lines << "Performance:"
      lines.concat(format_performance(result.performance))
      lines << ""
      lines << "Tools:"
      lines.concat(format_tools(result.tools))
      lines << ""
      lines << "Errors:"
      lines.concat(format_errors(result.errors))
      lines.join("\n")
    end

    def self.normalize_unit(unit)
      text = unit.to_s.downcase
      text = text.delete_suffix("s")
      UNITS.include?(text) ? text : nil
    end

    def self.normalize_bucket(bucket)
      text = bucket.to_s.downcase.strip
      text = text.delete_suffix("s")
      raise ArgumentError, "Bucket must be one of: #{TOKEN_BUCKETS.join(", ")}" unless TOKEN_BUCKETS.include?(text)

      text
    end

    def self.calendar_start(now, count, unit)
      case unit
      when "minute"
        Time.utc(now.year, now.month, now.day, now.hour, now.min) - ((count - 1) * 60)
      when "hour"
        Time.utc(now.year, now.month, now.day, now.hour) - ((count - 1) * 60 * 60)
      when "day"
        Time.utc(now.year, now.month, now.day) - ((count - 1) * 24 * 60 * 60)
      when "week"
        start_of_week = Time.utc(now.year, now.month, now.day) - ((now.wday + 6) % 7 * 24 * 60 * 60)
        start_of_week - ((count - 1) * 7 * 24 * 60 * 60)
      when "month"
        shift_month_start(now, -(count - 1))
      when "year"
        Time.utc(now.year - count + 1, 1, 1)
      else
        raise ArgumentError, USAGE
      end
    end

    def self.shift_month_start(now, offset)
      month_index = (now.year * 12) + (now.month - 1) + offset
      year = month_index / 12
      month = (month_index % 12) + 1
      Time.utc(year, month, 1)
    end

    def self.format_counts(counts)
      return ["  none"] if counts.empty?

      counts.sort_by { |key, value| [-value, key.to_s] }.map { |key, value| "  #{key}: #{value}" }
    end

    def self.format_tokens(tokens)
      lines = ["  model usage events: #{tokens[:modelUsageEvents]}"]
      if tokens[:totals].empty?
        lines << "  token totals: none"
      else
        tokens[:totals].sort.each { |key, value| lines << "  #{key}: #{value}" }
      end
      lines
    end

    def self.format_performance(performance)
      return ["  none"] if performance[:events].empty?

      lines = []
      performance[:events].sort.each do |event, stats|
        lines << "  #{event}: count=#{stats[:count]}, min=#{stats[:durationMs][:min]}, avg=#{stats[:durationMs][:avg]}, max=#{stats[:durationMs][:max]} ms"
        lines << "    statuses: #{inline_counts(stats[:statuses])}" unless stats[:statuses].empty?
      end
      lines
    end

    def self.format_tools(tools)
      lines = ["  calls: #{tools[:calls]}", "  result bytes: #{tools[:resultBytes]}"]
      lines << "  by tool: #{inline_counts(tools[:byName])}"
      lines << "  by status: #{inline_counts(tools[:byStatus])}"
      lines
    end

    def self.format_errors(errors)
      lines = ["  events: #{errors[:count]}"]
      lines << "  by event: #{inline_counts(errors[:byEvent])}"
      lines << "  by class: #{inline_counts(errors[:byClass])}"
      lines << "  by provider: #{inline_counts(errors[:byProvider])}"
      lines << "  by code: #{inline_counts(errors[:byCode])}"
      lines
    end

    def self.inline_counts(counts)
      return "none" if counts.empty?

      counts.sort_by { |key, value| [-value, key.to_s] }.map { |key, value| "#{key}=#{value}" }.join(", ")
    end

    private

    def read_records(start_at, end_at, categories)
      records = []
      each_record(start_at, end_at, categories) { |record, _timestamp| records << record }
      records
    end

    def each_record(start_at, end_at, categories, reverse: false, stop_before_start: false)
      return enum_for(:each_record, start_at, end_at, categories, reverse: reverse, stop_before_start: stop_before_start) unless block_given?
      return unless Dir.exist?(log_dir)

      category_set = categories.each_with_object({}) { |category, result| result[category] = true }
      paths = log_paths_for_range(start_at, end_at)
      paths = paths.reverse if reverse
      paths.each do |path|
        stop_file = false
        each_line = reverse ? method(:reverse_each_line) : method(:forward_each_line)
        each_line.call(path) do |line|
          record = JSON.parse(line)
          timestamp = parse_timestamp(record["timestamp"])
          next unless timestamp
          if stop_before_start && timestamp < start_at
            stop_file = true
            break
          end
          next unless timestamp >= start_at && timestamp <= end_at
          next unless category_set[record["category"].to_s]

          yield record, timestamp
        rescue JSON::ParserError
          nil
        end
        next if stop_file
      end
    end

    def forward_each_line(path, &block)
      File.foreach(path, chomp: true, &block)
    end

    def reverse_each_line(path, chunk_size: 64 * 1024)
      File.open(path, "rb") do |file|
        position = file.size
        buffer = +""
        while position.positive?
          read_size = [chunk_size, position].min
          position -= read_size
          file.seek(position)
          buffer = file.read(read_size) + buffer
          lines = buffer.split("\n", -1)
          buffer = lines.shift
          lines.pop if position + read_size == file.size && lines.last == ""
          lines.reverse_each { |line| yield line.chomp }
        end
        yield buffer.chomp unless buffer.empty?
      end
    end

    def log_paths_for_range(start_at, end_at)
      return [] unless Dir.exist?(log_dir)

      start_date = start_at.utc.strftime("%Y-%m-%d")
      end_date = end_at.utc.strftime("%Y-%m-%d")
      Dir[File.join(log_dir, "*.jsonl")].select do |path|
        date = File.basename(path)[/\A\d{4}-\d{2}-\d{2}/]
        date && date >= start_date && date <= end_date
      end.sort
    end

    def parse_timestamp(value)
      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def token_usage_buckets(range, bucket)
      buckets = {}
      each_record(range[:start_at], range[:end_at], ["tokens"], reverse: true, stop_before_start: true) do |record, timestamp|
        next unless record["event"] == "model_usage"

        usage = record["usage"]
        next unless usage.is_a?(Hash)

        start_at = bucket_start(timestamp, bucket)
        end_at = bucket_end(start_at, bucket)
        key = [start_at, record["provider"].to_s, record["model"].to_s]
        values = buckets[key] ||= token_csv_bucket(start_at, end_at, record)
        values["events"] += 1
        %w[input_tokens output_tokens cache_read_tokens cache_write_tokens total_tokens].each do |column|
          values[column] += usage[column].to_i if usage[column].is_a?(Numeric)
        end
      end
      buckets.sort_by { |(start_at, provider, model), _values| [start_at, provider, model] }.to_h
    end

    def token_csv_bucket(start_at, end_at, record)
      TOKEN_CSV_HEADER.each_with_object({}) do |column, result|
        result[column] = 0
      end.merge(
        "bucket_start" => start_at.iso8601,
        "bucket_end" => end_at.iso8601,
        "provider" => record["provider"].to_s,
        "model" => record["model"].to_s
      )
    end

    def token_csv_value(values, column)
      return values[column] if %w[bucket_start bucket_end provider model].include?(column)

      values[column] || 0
    end

    def csv_row(values)
      values.map { |value| csv_escape(value) }.join(",")
    end

    def csv_escape(value)
      text = value.to_s
      return text unless text.match?(/[",\n\r]/)

      "\"#{text.gsub("\"", "\"\"")}\""
    end

    def bucket_start(timestamp, bucket)
      case bucket
      when "second"
        Time.utc(timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.min, timestamp.sec)
      when "minute"
        Time.utc(timestamp.year, timestamp.month, timestamp.day, timestamp.hour, timestamp.min)
      when "hour"
        Time.utc(timestamp.year, timestamp.month, timestamp.day, timestamp.hour)
      when "day"
        Time.utc(timestamp.year, timestamp.month, timestamp.day)
      when "week"
        Time.utc(timestamp.year, timestamp.month, timestamp.day) - ((timestamp.wday + 6) % 7 * 24 * 60 * 60)
      when "month"
        Time.utc(timestamp.year, timestamp.month, 1)
      when "year"
        Time.utc(timestamp.year, 1, 1)
      else
        raise ArgumentError, "Bucket must be one of: #{TOKEN_BUCKETS.join(", ")}"
      end
    end

    def bucket_end(start_at, bucket)
      case bucket
      when "second"
        start_at + 1
      when "minute"
        start_at + 60
      when "hour"
        start_at + (60 * 60)
      when "day"
        start_at + (24 * 60 * 60)
      when "week"
        start_at + (7 * 24 * 60 * 60)
      when "month"
        self.class.shift_month_start(start_at, 1)
      when "year"
        Time.utc(start_at.year + 1, 1, 1)
      end
    end

    def build_result(range, categories, records)
      Result.new(
        range: range,
        log_dir: log_dir,
        enabled_categories: categories,
        record_count: records.length,
        records_by_category: count_by(records) { |record| record["category"] },
        records_by_event: count_by(records) { |record| record["event"] },
        tokens: token_stats(records),
        performance: performance_stats(records),
        tools: tool_stats(records),
        errors: error_stats(records)
      )
    end

    def count_by(records)
      records.each_with_object({}) do |record, counts|
        key = yield(record).to_s
        next if key.empty?

        counts[key] = counts.fetch(key, 0) + 1
      end
    end

    def token_stats(records)
      usage_records = records.select { |record| record["category"] == "tokens" && record["event"] == "model_usage" }
      totals = Hash.new(0)
      usage_records.each do |record|
        usage = record["usage"]
        next unless usage.is_a?(Hash)

        usage.each do |key, value|
          totals[key.to_s] += value if value.is_a?(Numeric)
        end
      end
      { modelUsageEvents: usage_records.length, totals: totals.sort.to_h }
    end

    def performance_stats(records)
      events = {}
      records.select { |record| record["category"] == "performance" }.each do |record|
        event = record["event"].to_s
        next if event.empty?

        stats = events[event] ||= { count: 0, statuses: Hash.new(0), durations: [] }
        stats[:count] += 1
        status = record["status"].to_s
        stats[:statuses][status] += 1 unless status.empty?
        stats[:durations] << record["duration_ms"].to_f if record["duration_ms"].is_a?(Numeric)
      end

      normalized = events.each_with_object({}) do |(event, stats), result|
        result[event] = {
          count: stats[:count],
          statuses: stats[:statuses].sort.to_h,
          durationMs: duration_stats(stats[:durations])
        }
      end
      { events: normalized }
    end

    def duration_stats(values)
      return { min: nil, avg: nil, max: nil } if values.empty?

      {
        min: values.min.round(1),
        avg: (values.sum / values.length).round(1),
        max: values.max.round(1)
      }
    end

    def tool_stats(records)
      tool_records = records.select { |record| record["category"] == "tools" && record["event"] == "tool_call" }
      {
        calls: tool_records.length,
        resultBytes: tool_records.sum { |record| record["result_bytes"].is_a?(Numeric) ? record["result_bytes"] : 0 },
        byName: count_by(tool_records) { |record| record["tool_name"] },
        byStatus: count_by(tool_records) { |record| record["status"] }
      }
    end

    def error_stats(records)
      error_records = records.select { |record| record["category"] == "errors" }
      {
        count: error_records.length,
        byEvent: count_by(error_records) { |record| record["event"] },
        byClass: count_by(error_records) { |record| record["error_class"] },
        byProvider: count_by(error_records) { |record| record["provider"] },
        byCode: count_by(error_records) { |record| record["error_code"] }
      }
    end
  end
end
