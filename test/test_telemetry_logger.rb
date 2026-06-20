require_relative "test_helper"

class TestTelemetryLogger < KwardTestCase
  def test_logging_defaults_off
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump({}))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      refute logger.enabled?("tokens")
      refute logger.log("tokens", "model_usage", "usage" => { "total_tokens" => 1 })
      refute Dir.exist?(File.join(dir, "logs"))
    end
  end

  def test_category_requires_enabled_flag
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "tokens" => true }))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      refute logger.enabled?("tokens")
    end
  end

  def test_environment_overrides_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => false, "tokens" => false }))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      with_env("KWARD_LOGGING" => "true", "KWARD_LOGGING_TOKENS" => "true") do
        assert logger.enabled?("tokens")
      end
    end
  end

  def test_compaction_logging_can_be_enabled
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "compaction" => true }))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      assert logger.log("compaction", "tool_output", "bytes_before" => 100, "bytes_after" => 40)

      path = Dir[File.join(dir, "logs", "*.jsonl")].first
      record = jsonl_records(path).first
      assert_equal "compaction", record["category"]
      assert_equal "tool_output", record["event"]
      assert_equal 100, record["bytes_before"]
    end
  end

  def test_writes_redacted_jsonl_record_under_config_dir_logs
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "errors" => true }))
      logger = Kward::TelemetryLogger.new(config_path: config_path)

      logger.log("errors", "model_error", "authorization" => "Bearer secret-token", "error_message" => "failed sk-testsecret")

      path = Dir[File.join(dir, "logs", "*.jsonl")].first
      record = jsonl_records(path).first
      assert_equal "errors", record["category"]
      assert_equal "model_error", record["event"]
      assert_equal "[REDACTED]", record["authorization"]
      assert_equal "failed [REDACTED]", record["error_message"]
    end
  end

  def test_rotates_when_current_file_reaches_limit
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      base = File.join(log_dir, "#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl")
      File.write(base, "x" * 20)
      logger = Kward::TelemetryLogger.new(config_path: config_path, max_bytes: 10)

      logger.log("tokens", "model_usage", "usage" => { "total_tokens" => 1 })

      assert File.exist?(base.sub(/\.jsonl\z/, "-1.jsonl"))
    end
  end
end
