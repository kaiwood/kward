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

  class RuntimeCaptureClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def chat(_messages, tools: [], provider: nil, model: nil, reasoning: nil, **_kwargs)
      @calls << { provider: provider, model: model, reasoning: reasoning, tools: tools }
      { "role" => "assistant", "content" => "ok", "provider" => provider, "model" => model }
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

  class SteeringContinuationClient
    attr_reader :seen_messages

    def initialize
      @seen_messages = []
      @first_call_started = Queue.new
    end

    def wait_for_first_call
      @first_call_started.pop
    end

    def chat(messages, tools: [], on_assistant_delta: nil, steering: nil, **_kwargs)
      @seen_messages << messages.map(&:dup)
      if @seen_messages.length == 1
        @first_call_started << true
        on_assistant_delta&.call("initial")
        sleep 0.08
        return { "role" => "assistant", "content" => "initial" }
      end

      on_assistant_delta&.call("continued")
      { "role" => "assistant", "content" => "continued" }
    end
  end

  def test_agent_runs_turn_and_model_lifecycle_hooks
    manager = Kward::Hooks::Manager.new
    events = []
    manager.register("turn_start") do |event, _ctx|
      events << [event.name, event.payload[:input]]
      Kward::Hooks::Decision.modify(input: "modified prompt")
    end
    manager.register("model_request_before") do |event, _ctx|
      events << [event.name, event.payload[:messages].last[:content]]
      Kward::Hooks::Decision.modify(model: "hook-model")
    end
    manager.register("model_response_after_parse") do |event, _ctx|
      events << [event.name, event.payload[:message]["content"]]
      Kward::Hooks::Decision.allow
    end
    manager.register("turn_end") do |event, _ctx|
      events << [event.name, event.payload[:answer]]
      Kward::Hooks::Decision.allow
    end
    conversation = Kward::Conversation.new(system_message: nil, model: "original-model")
    client = RuntimeCaptureClient.new
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new, conversation: conversation, hook_manager: manager)

    answer = agent.ask("hello")

    assert_equal "ok", answer
    assert_equal "hook-model", client.calls.first[:model]
    assert_equal [
      ["turn_start", "hello"],
      ["model_request_before", "modified prompt"],
      ["model_response_after_parse", "ok"],
      ["turn_end", "ok"]
    ], events
  end

  def test_agent_passes_and_persists_conversation_runtime_after_model_request
    conversation = Kward::Conversation.new(system_message: nil, provider: "OpenRouter", model: "openai/gpt-test", reasoning_effort: "high")
    persisted = []
    conversation.on_runtime_update = lambda { |provider:, model:, reasoning_effort:| persisted << { provider: provider, model: model, reasoning_effort: reasoning_effort } }
    client = RuntimeCaptureClient.new
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new, conversation: conversation)

    answer = agent.ask("hello")

    assert_equal "ok", answer
    assert_equal 1, client.calls.length
    assert_equal "OpenRouter", client.calls.first[:provider]
    assert_equal "openai/gpt-test", client.calls.first[:model]
    assert_equal "high", client.calls.first[:reasoning]
    assert_equal [{ provider: "OpenRouter", model: "openai/gpt-test", reasoning_effort: "high" }], persisted
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

  def test_agent_persists_steering_and_continues_same_turn
    client = SteeringContinuationClient.new
    conversation = Kward::Conversation.new(system_message: nil)
    steering = Kward::Steering.new
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new, conversation: conversation)
    events = []

    worker = Thread.new do
      agent.ask("first", steering: steering) { |event| events << event }
    end
    client.wait_for_first_call
    steering.submit("steer one")
    steering.submit("steer two")
    answer = worker.value

    assert_equal "continued", answer
    assert_equal 2, client.seen_messages.length
    assert_equal ["first", "steer one", "steer two"], conversation.messages.select { |message| message[:role] == "user" }.map { |message| message[:content] }
    assert_equal ["first"], client.seen_messages.first.map { |message| message[:content] || message["content"] }
    assert_equal ["first", "initial", "steer one", "steer two"], client.seen_messages.last.map { |message| message[:content] || message["content"] }
    assert_equal ["steer one", "steer two"], events.grep(Kward::Events::Steering).map(&:input)
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
    Dir.mktmpdir do |dir|
      path = "kward_agent_edit.txt"
      File.write(File.join(dir, path), "old\n")
      client = FakeClient.new([
        assistant_tool_call("read_file", path: path),
        assistant_tool_call("edit_file", path: path, edits: [{ old_text: "old", new_text: "new" }]),
        { "role" => "assistant", "content" => "I edited the file." }
      ])
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))
      agent = Kward::Agent.new(client: client, tool_registry: registry)

      answer = agent.ask("edit it")

      assert_equal "I edited the file.", answer
      assert_equal "new\n", File.read(File.join(dir, path))
    end
  end

  def test_agent_rejects_file_change_claim_without_file_tool
    client = FakeClient.new([{ "role" => "assistant", "content" => "I changed the file." }])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new)

    answer = agent.ask("edit it")

    assert_equal "I have not changed any files. I need to use write_file or edit_file successfully before claiming a file change.", answer
  end

  def test_agent_rejects_file_change_claim_after_failed_file_tool
    Dir.mktmpdir do |dir|
      path = "kward_agent_failed_edit.txt"
      File.write(File.join(dir, path), "old\n")
      client = FakeClient.new([
        assistant_tool_call("edit_file", path: path, edits: [{ old_text: "old", new_text: "new" }]),
        { "role" => "assistant", "content" => "I edited the file." }
      ])
      registry = Kward::ToolRegistry.new(workspace: Kward::Workspace.new(root: dir))
      agent = Kward::Agent.new(client: client, tool_registry: registry)

      answer = agent.ask("edit it")

      assert_equal "The file change tool returned an error or declined result, so I did not successfully change the file.", answer
      assert_equal "old\n", File.read(File.join(dir, path))
    end
  end

  def test_agent_does_not_rewrite_non_file_change_claims
    client = FakeClient.new([{ "role" => "assistant", "content" => "I updated my understanding of the issue." }])
    agent = Kward::Agent.new(client: client, tool_registry: Kward::ToolRegistry.new)

    answer = agent.ask("think about it")

    assert_equal "I updated my understanding of the issue.", answer
  end

end
