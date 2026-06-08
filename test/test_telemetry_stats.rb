require_relative "test_helper"

class TestTelemetryStats < KwardTestCase
  class FixedClock
    def initialize(now)
      @now = now
    end

    def now
      @now
    end
  end

  def test_parse_range_defaults_to_current_calendar_week
    now = Time.utc(2025, 3, 15, 12, 34, 56)

    range = Kward::TelemetryStats.parse_range("", now: now)

    assert_equal "1 week", range[:input]
    assert_equal Time.utc(2025, 3, 10), range[:start_at]
    assert_equal now, range[:end_at]
  end

  def test_parse_range_supports_current_and_previous_calendar_months
    now = Time.utc(2025, 3, 15, 12, 34, 56)

    range = Kward::TelemetryStats.parse_range("2 months", now: now)

    assert_equal Time.utc(2025, 2, 1), range[:start_at]
  end

  def test_parse_range_rejects_invalid_arguments
    error = assert_raises(ArgumentError) do
      Kward::TelemetryStats.parse_range("banana", now: Time.utc(2025, 1, 1))
    end

    assert_equal Kward::TelemetryStats::USAGE, error.message
  end

  def test_collect_aggregates_enabled_categories_without_error_messages
    Dir.mktmpdir do |dir|
      now = Time.utc(2025, 5, 10, 12, 0, 0)
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true, "performance" => true, "tools" => true, "errors" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "2025-05-10.jsonl"), [
        JSON.generate("timestamp" => "2025-05-10T10:00:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15 }),
        JSON.generate("timestamp" => "2025-05-10T10:01:00.000Z", "category" => "performance", "event" => "model_request", "duration_ms" => 123.4, "status" => "ok"),
        JSON.generate("timestamp" => "2025-05-10T10:02:00.000Z", "category" => "tools", "event" => "tool_call", "tool_name" => "read_file", "status" => "ok", "result_bytes" => 20),
        JSON.generate("timestamp" => "2025-05-10T10:03:00.000Z", "category" => "errors", "event" => "model_error", "error_class" => "RuntimeError", "provider" => "Codex", "error_code" => "500", "error_message" => "redacted detail"),
        JSON.generate("timestamp" => "2025-04-01T10:03:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 999 }),
        "not json"
      ].join("\n"))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      result = Kward::TelemetryStats.new(telemetry_logger: logger, clock: FixedClock.new(now)).collect("1 day")
      formatted = Kward::TelemetryStats.format(result)

      assert_equal 4, result.record_count
      assert_equal({ "tokens" => 1, "performance" => 1, "tools" => 1, "errors" => 1 }, result.records_by_category)
      assert_equal 15, result.tokens[:totals]["total_tokens"]
      assert_equal 123.4, result.performance[:events]["model_request"][:durationMs][:avg]
      assert_equal({ "read_file" => 1 }, result.tools[:byName])
      assert_equal({ "RuntimeError" => 1 }, result.errors[:byClass])
      assert_includes formatted, "total_tokens: 15"
      refute_includes formatted, "redacted detail"
    end
  end

  def test_token_usage_csv_groups_token_usage_by_hour_for_short_ranges
    Dir.mktmpdir do |dir|
      now = Time.utc(2025, 5, 10, 12, 30, 0)
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "2025-05-10.jsonl"), [
        JSON.generate("timestamp" => "2025-05-10T07:59:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 999 }),
        JSON.generate("timestamp" => "2025-05-10T08:05:00.000Z", "category" => "tokens", "event" => "model_usage", "provider" => "openrouter", "model" => "alpha", "usage" => { "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15 }),
        JSON.generate("timestamp" => "2025-05-10T08:55:00.000Z", "category" => "tokens", "event" => "model_usage", "provider" => "openrouter", "model" => "alpha", "usage" => { "input_tokens" => 20, "output_tokens" => 7, "cache_read_tokens" => 3, "total_tokens" => 30 }),
        JSON.generate("timestamp" => "2025-05-10T12:10:00.000Z", "category" => "tokens", "event" => "model_usage", "provider" => "openrouter", "model" => "beta", "usage" => { "input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3 })
      ].join("\n"))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      csv = Kward::TelemetryStats.new(telemetry_logger: logger, clock: FixedClock.new(now)).token_usage_csv("5 hours", bucket: "hour")
      rows = csv.lines.map { |line| line.chomp.split(",") }

      assert_equal ["bucket_start", "bucket_end", "provider", "model", "events", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "total_tokens"], rows[0]
      assert_equal 3, rows.length
      assert_equal "2025-05-10T08:00:00Z", rows[1][0]
      assert_equal "openrouter", rows[1][2]
      assert_equal "alpha", rows[1][3]
      assert_equal "2", rows[1][4]
      assert_equal "30", rows[1][5]
      assert_equal "12", rows[1][6]
      assert_equal "3", rows[1][7]
      assert_equal "45", rows[1][9]
      assert_equal "2025-05-10T12:00:00Z", rows[2][0]
    end
  end

  def test_token_usage_csv_skips_log_files_outside_date_range
    Dir.mktmpdir do |dir|
      now = Time.utc(2025, 5, 10, 12, 30, 0)
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      FileUtils.mkdir_p(File.join(log_dir, "2024-01-01.jsonl"))
      File.write(File.join(log_dir, "2025-05-10-1.jsonl"), JSON.generate("timestamp" => "2025-05-10T12:10:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 3 }) + "\n")
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      csv = Kward::TelemetryStats.new(telemetry_logger: logger, clock: FixedClock.new(now)).token_usage_csv("5 hours", bucket: "hour")

      assert_includes csv, "2025-05-10T12:00:00Z"
      assert_includes csv, ",3\n"
    end
  end

  def test_token_usage_csv_supports_second_bucket
    Dir.mktmpdir do |dir|
      now = Time.utc(2025, 5, 10, 12, 0, 2)
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "2025-05-10.jsonl"), [
        JSON.generate("timestamp" => "2025-05-10T12:00:01.100Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 2 }),
        JSON.generate("timestamp" => "2025-05-10T12:00:01.900Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 3 })
      ].join("\n") + "\n")
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      csv = Kward::TelemetryStats.new(telemetry_logger: logger, clock: FixedClock.new(now)).token_usage_csv("1 minute", bucket: "seconds")

      assert_includes csv, "2025-05-10T12:00:01Z,2025-05-10T12:00:02Z,,,2,0,0,0,0,5"
    end
  end

  def test_token_usage_csv_reverse_scans_cross_day_short_range
    Dir.mktmpdir do |dir|
      now = Time.utc(2025, 5, 10, 3, 0, 0)
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      old_lines = Array.new(1000) { JSON.generate("timestamp" => "2025-05-09T10:00:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 999 }) }
      recent_line = JSON.generate("timestamp" => "2025-05-09T23:30:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 7 })
      stop_line = JSON.generate("timestamp" => "2025-05-09T14:59:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 999 })
      File.write(File.join(log_dir, "2025-05-09.jsonl"), (old_lines + [stop_line, recent_line]).join("\n") + "\n")
      File.write(File.join(log_dir, "2025-05-10.jsonl"), [
        JSON.generate("timestamp" => "2025-05-10T01:30:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 2 }),
        JSON.generate("timestamp" => "2025-05-10T02:30:00.000Z", "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 3 })
      ].join("\n") + "\n")
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      csv = Kward::TelemetryStats.new(telemetry_logger: logger, clock: FixedClock.new(now)).token_usage_csv("12 hours", bucket: "hour")

      assert_includes csv, "2025-05-09T23:00:00Z"
      assert_includes csv, ",7\n"
      assert_includes csv, "2025-05-10T01:00:00Z"
      assert_includes csv, ",2\n"
      assert_includes csv, "2025-05-10T02:00:00Z"
      assert_includes csv, ",3\n"
      refute_includes csv, "999"
    end
  end

  def test_collect_requires_enabled_logging
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => false, "tokens" => true }))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      error = assert_raises(ArgumentError) do
        Kward::TelemetryStats.new(telemetry_logger: logger, clock: FixedClock.new(Time.utc(2025, 1, 1))).collect("1 day")
      end

      assert_includes error.message, "Telemetry logging is disabled"
    end
  end
end
