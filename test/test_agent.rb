require_relative "test_helper"

class TestAgent < KwardTestCase
  class OverflowThenSummaryClient
    attr_reader :main_message_counts, :main_token_counts, :summary_calls

    def initialize
      @main_message_counts = []
      @main_token_counts = []
      @summary_calls = 0
    end

    def chat(messages, tools: [], **_kwargs)
      if tools.empty?
        @summary_calls += 1
        return { "role" => "assistant", "content" => "## Goal\nContinue after overflow compaction." }
      end

      @main_message_counts << messages.length
      @main_token_counts << Kward::Compaction::TokenEstimator.new.messages_tokens(messages)
      if @main_message_counts.length == 1
        raise Kward::Client::RequestError.new(
          provider: "OpenRouter",
          code: 400,
          body: "This endpoint's maximum context length is 128000 tokens. However, you requested about 130000 tokens."
        )
      end

      { "role" => "assistant", "content" => "done after retry" }
    end

    def current_context_window
      nil
    end
  end

  class ArgumentErrorAfterChatClient
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def chat(_messages, tools: [], **_kwargs)
      @calls += 1
      raise ArgumentError, "unknown keyword: :on_retry"
    end
  end

  def test_context_overflow_compacts_and_retries_once
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "compaction" => { "keep_recent_tokens" => 10 } }))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(system_message: nil)
        conversation.append_user("old request " + ("details " * 1_000))
        conversation.append_assistant("old reply " + ("details " * 1_000))
        client = OverflowThenSummaryClient.new
        agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new, conversation: conversation)

        answer = agent.ask("continue")

        assert_equal "done after retry", answer
        assert_equal [3, 2], client.main_message_counts
        assert_operator client.main_token_counts.first, :>, 4_000
        assert_operator client.main_token_counts.last, :<, 100
        assert_equal 1, client.summary_calls
        assert_equal ["compactionSummary", "user", "assistant"], conversation.messages.map { |message| message[:role] || message["role"] }
      end
    end
  end

  def test_agent_does_not_retry_argument_errors_from_custom_client
    client = ArgumentErrorAfterChatClient.new
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new)

    assert_raises(ArgumentError) do
      agent.ask("hello")
    end
    assert_equal 1, client.calls
  end

  def test_agent_logs_tool_metadata_without_arguments_or_output
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tools" => true, "performance" => true }))
      path = File.join(dir, "secret.txt")
      File.write(path, "very secret file output\n")
      client = FakeClient.new([
        assistant_tool_call("read_file", path: path),
        { "role" => "assistant", "content" => "done" }
      ])
      logger = Kward::TelemetryLogger.new(config_path: config_path)
      agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new, telemetry_logger: logger)

      agent.ask("read it")

      records = Dir[File.join(dir, "logs", "*.jsonl")].flat_map { |log_path| jsonl_records(log_path) }
      tool_record = records.find { |record| record["category"] == "tools" && record["event"] == "tool_call" }
      assert_equal "read_file", tool_record["tool_name"]
      assert_equal "completed", tool_record["status"]
      assert_operator tool_record["result_bytes"], :>, 0
      serialized = records.map(&:to_json).join("\n")
      refute_includes serialized, path
      refute_includes serialized, "very secret file output"
    end
  end

  def test_agent_allows_claim_after_successful_edit_file
    path = "kward_agent_edit.txt"
    File.write(path, "old\n")
    client = FakeClient.new([
      assistant_tool_call("read_file", path: path),
      assistant_tool_call("edit_file", path: path, edits: [{ old_text: "old", new_text: "new" }]),
      { "role" => "assistant", "content" => "I edited the file." }
    ])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new)

    answer = agent.ask("edit it")

    assert_equal "I edited the file.", answer
    assert_equal "new\n", File.read(path)
  ensure
    File.delete(path) if path && File.exist?(path)
  end

end
