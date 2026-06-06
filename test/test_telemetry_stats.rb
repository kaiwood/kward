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
