require_relative "test_helper"

class TestDateTimeTool < KwardTestCase
  def test_datetime_tool_is_advertised_and_can_be_filtered
    registry = Kward::ToolRegistry.new
    datetime_schema = registry.schemas.find { |schema| schema[:function][:name] == "datetime" }

    assert datetime_schema
    assert_equal %w[current_time add_seconds], datetime_schema.dig(:function, :parameters, :properties, :operation, :enum)
    allowed_names = Kward::ToolRegistry.new(allowed_tool_names: ["read_file"]).schemas.map { |schema| schema[:function][:name] }
    refute_includes allowed_names, "datetime"
  end

  def test_current_time_returns_iso8601_in_requested_offset
    result = dispatch_datetime(operation: "current_time", timezone_offset: "+05:30")

    time = Time.iso8601(result.delete_prefix("Current date/time: "))
    assert_equal 19_800, time.utc_offset
  end

  def test_current_time_defaults_to_host_local_timezone
    with_env("TZ" => "UTC") do
      result = dispatch_datetime(operation: "current_time")
      time = Time.iso8601(result.delete_prefix("Current date/time: "))

      assert_equal 0, time.utc_offset
    end
  end

  def test_current_time_accepts_utc_and_rejects_invalid_offsets
    utc_time = dispatch_datetime(operation: "current_time", timezone_offset: "Z")
    assert_equal 0, Time.iso8601(utc_time.delete_prefix("Current date/time: ")).utc_offset
    invalid_offset = dispatch_datetime(operation: "current_time", timezone_offset: "+14:30")
    assert_equal "Error: timezone_offset must be Z or an offset between -14:00 and +14:00", invalid_offset
  end

  def test_add_seconds_preserves_timestamp_offset
    result = dispatch_datetime(
      operation: "add_seconds",
      timestamp: "2024-01-01T23:30:00-05:00",
      seconds: 3600
    )

    assert_equal "Result: 2024-01-02T00:30:00-05:00", result
  end

  def test_add_seconds_supports_negative_values_and_validates_arguments
    result = dispatch_datetime(
      operation: "add_seconds",
      timestamp: "2024-01-01T00:00:00+02:00",
      seconds: -60
    )

    assert_equal "Result: 2023-12-31T23:59:00+02:00", result
    invalid_timestamp = dispatch_datetime(operation: "add_seconds", timestamp: "not a timestamp", seconds: 1)
    assert_match(/Error: timestamp must be an ISO 8601 string with a UTC offset/, invalid_timestamp)
    missing_offset = dispatch_datetime(operation: "add_seconds", timestamp: "2024-01-01T00:00:00", seconds: 1)
    assert_match(/Error: timestamp must be an ISO 8601 string with a UTC offset/, missing_offset)
    invalid_seconds = dispatch_datetime(operation: "add_seconds", timestamp: "2024-01-01T00:00:00Z", seconds: 1.5)
    assert_equal "Error: seconds must be an integer", invalid_seconds
  end

  private

  def dispatch_datetime(**arguments)
    registry = Kward::ToolRegistry.new
    registry.dispatch(tool_call("datetime", arguments), Kward::Conversation.new(system_message: nil))
  end
end
