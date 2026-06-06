require "json"
require "time"
require_relative "config_files"
require_relative "telemetry_logger"

module Kward
  class TelemetryStats
    DEFAULT_RANGE = "1 week"
    UNITS = %w[minute hour day week month year].freeze
    USAGE = "Usage: /stats [N minutes|hours|days|weeks|months|years] (default: 1 week)".freeze

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
      return [] unless Dir.exist?(log_dir)

      category_set = categories.each_with_object({}) { |category, result| result[category] = true }
      Dir[File.join(log_dir, "*.jsonl")].sort.flat_map do |path|
        File.readlines(path, chomp: true).filter_map do |line|
          record = JSON.parse(line)
          timestamp = parse_timestamp(record["timestamp"])
          next unless timestamp && timestamp >= start_at && timestamp <= end_at
          next unless category_set[record["category"].to_s]

          record
        rescue JSON::ParserError
          nil
        end
      end
    end

    def parse_timestamp(value)
      Time.parse(value.to_s).utc
    rescue ArgumentError
      nil
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
