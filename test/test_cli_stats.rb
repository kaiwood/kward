require_relative "test_helper"

class TestCLIStats < KwardTestCase
  def test_stats_slash_command_prints_logging_summary_without_calling_client
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl"), JSON.generate("timestamp" => Time.now.utc.iso8601(3), "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 7 }) + "\n")
      prompt = FakePrompt.new(["/stats 1 day", "/exit"])
      client = RecordingClient.new([])
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
      cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.interactive_loop(agent: agent)
      end

      output = prompt.output.join("\n")
      assert_includes output, "Stats for 1 day"
      assert_includes output, "total_tokens: 7"
      assert_empty client.seen_messages
    end
  end

  def test_stats_tokens_command_writes_csv_without_calling_client
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl"), JSON.generate("timestamp" => Time.now.utc.iso8601(3), "category" => "tokens", "event" => "model_usage", "provider" => "openrouter", "model" => "alpha", "usage" => { "input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5 }) + "\n")
      output_path = File.join(dir, "tokens.csv")
      client = RecordingClient.new([])
      cli = Kward::CLI.new(argv: ["stats", "tokens", "5", "hours", "--bucket", "hour", "--output", output_path], stdin: FakeInput.new("", tty: true), prompt: FakePrompt.new([]), client: client)

      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli.run
      end

      csv = File.read(output_path)
      assert_includes csv, "bucket_start,bucket_end,provider,model,events,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,total_tokens"
      assert_includes csv, "openrouter,alpha,1,2,3,0,0,5"
      assert_empty client.seen_messages
    end
  end

  def test_stats_slash_command_prints_usage_for_invalid_range
    prompt = FakePrompt.new(["/stats banana", "/exit"])
    client = RecordingClient.new([])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new(prompt: prompt))
    cli = Kward::CLI.new(argv: [], stdin: FakeInput.new("", tty: true), prompt: prompt, client: client)

    with_env("KWARD_LOGGING" => "true", "KWARD_LOGGING_TOKENS" => "true") do
      cli.interactive_loop(agent: agent)
    end

    assert_includes prompt.output.join("\n"), Kward::TelemetryStats::USAGE
    assert_empty client.seen_messages
  end

end
