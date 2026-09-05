require_relative "test_helper"

class TestPluginTurnRequest < KwardTestCase
  def request(text = "Answer with the ship's name.")
    Kward::PluginTurnRequest.new(system: text, command: "iddqd", plugin_id: "test.iddqd")
  end

  def context(cancellation: nil, enabled: true)
    command = Kward::PluginCommand.new(name: "iddqd", plugin_id: "test.iddqd") if enabled
    Kward::PluginRegistry::Context.new(conversation: Kward::Conversation.new(system_message: nil), cancellation: cancellation, turn_command: command)
  end

  def test_context_stages_one_immutable_request_without_executing
    ctx = context
    text = +"Reply in French."
    assert ctx.turn_requests_supported?
    assert_nil ctx.request_turn(system: text)
    text.replace("Changed")
    assert_equal "Reply in French.", ctx.requested_turn.system
    assert_equal "test.iddqd", ctx.requested_turn.plugin_id
    assert ctx.requested_turn.frozen?
    assert_raises(ArgumentError) { ctx.request_turn(system: "Another turn") }
    assert_empty ctx.transcript.messages
  end

  def test_validation_and_unsupported_contexts
    [nil, [], "", " \n", "x" * 65_537, "\xff".b.force_encoding("UTF-8")].each do |invalid|
      ctx = context
      assert_raises(ArgumentError) { ctx.request_turn(system: invalid) }
      assert_nil ctx.requested_turn
    end
    ctx = context(enabled: false)
    refute ctx.turn_requests_supported?
    assert_raises(ArgumentError) { ctx.request_turn(system: "Hello") }
    tool_context = context.for_tool(conversation: Kward::Conversation.new(system_message: nil))
    refute tool_context.turn_requests_supported?
    assert_raises(ArgumentError) { tool_context.request_turn(system: "Hello") }
  end

  def test_cancelled_context_does_not_stage_a_turn
    cancellation = Kward::Cancellation.new
    cancellation.cancel!
    ctx = context(cancellation: cancellation)
    assert_raises(Kward::Cancellation::CancelledError) { ctx.request_turn(system: "Hello") }
    assert_nil ctx.requested_turn
  end

  def test_agent_sends_system_instructions_once_and_preserves_history
    conversation = Kward::Conversation.new(system_message: { role: "system", content: "Base instructions" })
    client = RecordingClient.new(["Tauren", "Next answer"])
    agent = Kward::Agent.new(client: client, conversation: conversation)
    turn = request

    assert_equal "Tauren", agent.ask(turn)
    first = client.seen_messages.first
    assert_equal ["system", "system"], first.map { |message| message[:role] }
    assert_equal ["Base instructions", turn.system], first.map { |message| message[:content] }
    record = conversation.messages.first
    assert_equal turn.to_s, record[:display_content]
    assert_equal "turn", record[:plugin_system_turn][:scope]
    assert_equal turn.system, record[:plugin_system_turn][:system]
    refute_includes JSON.generate(conversation.context_messages), turn.system

    agent.ask("Next question")
    refute_includes JSON.generate(client.seen_messages.last), turn.system
    assert_equal "Base instructions", conversation.system_message[:content]
  end

  def test_scope_survives_prompt_refresh_and_compaction_and_cleans_up_on_error
    conversation = Kward::Conversation.new
    other = Kward::Conversation.new(system_message: nil)
    turn = request("Unique scoped instructions")
    assert_raises(RuntimeError) do
      conversation.with_system_turn(turn) do
        conversation.append_system_turn(turn)
        conversation.refresh_system_message!
        conversation.compact!("Summary", compaction_summary: true)
        assert_includes conversation.context_messages.map { |message| message[:content] }, turn.system
        refute_includes JSON.generate(other.context_messages), turn.system
        raise "Model failed"
      end
    end
    refute_includes JSON.generate(conversation.context_messages), turn.system
  end

  def test_model_failure_and_cancellation_do_not_leak_instructions
    [RuntimeError.new("provider failed"), Kward::Cancellation::CancelledError.new].each do |error|
      conversation = Kward::Conversation.new(system_message: nil)
      client = Object.new
      client.define_singleton_method(:chat) { |*args, **options| raise error }
      agent = Kward::Agent.new(client: client, conversation: conversation)
      assert_raises(error.class) { agent.ask(request("Temporary instructions")) }
      refute_includes JSON.generate(conversation.context_messages), "Temporary instructions"
    end
  end

  def test_system_instructions_remain_through_tool_continuation
    tool_call = { "id" => "call_1", "type" => "function", "function" => { "name" => "missing_tool", "arguments" => "{}" } }
    client = RecordingClient.new([{ "role" => "assistant", "content" => nil, "tool_calls" => [tool_call] }, "Done"])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Kward::Agent.new(client: client, conversation: conversation)
    turn = request
    agent.ask(turn)
    assert_equal 2, client.seen_messages.length
    client.seen_messages.each do |messages|
      assert_equal turn.system, messages.find { |message| message[:role] == "system" }[:content]
    end
    assert_equal "tool", conversation.messages[2][:role]
    refute_includes JSON.generate(conversation.context_messages), turn.system
  end

  def test_context_overflow_retry_retains_scoped_instructions
    conversation = Kward::Conversation.new(system_message: nil)
    client = RecordingClient.new(["Discarded", "Recovered"])
    client.define_singleton_method(:chat) do |messages, **options|
      response = super(messages, **options)
      if seen_messages.length == 1
        raise Kward::Client::RequestError.new(provider: "OpenRouter", code: 400, body: "maximum context length exceeded")
      end
      response
    end
    agent = Kward::Agent.new(client: client, conversation: conversation)
    agent.define_singleton_method(:compact_after_context_overflow) do |_error|
      conversation.compact!("Summary after overflow", compaction_summary: true)
    end
    turn = request("Scoped through retry")
    assert_equal "Recovered", agent.ask(turn)
    assert_equal 2, client.seen_messages.length
    client.seen_messages.each do |messages|
      assert_equal turn.system, messages.find { |message| message[:role] == "system" }[:content]
    end
    refute_includes JSON.generate(conversation.context_messages), turn.system
  end

  def test_provider_payloads_keep_instructions_out_of_user_content
    client = Kward::Client.new(api_key: nil, openai_access_token: "test-token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    conversation = Kward::Conversation.new(system_message: { role: "system", content: "Base rules" })
    conversation.append_user("Earlier question")
    conversation.append_assistant("Earlier answer")
    turn = request("Unique provider instructions")
    conversation.with_system_turn(turn) do
      conversation.append_system_turn(turn)
      messages = conversation.context_messages
      chat = client.send(:chat_messages, messages)
      assert_equal ["Base rules", turn.system], chat.select { |message| message[:role] == "system" }.map { |message| message[:content] }
      codex = client.send(:codex_payload, messages, [])
      assert_equal "Base rules", codex[:instructions]
      assert_equal %w[user assistant developer], codex[:input].map { |message| message[:role] }
      assert_equal [{ type: "input_text", text: turn.system }], codex[:input].last[:content]
      assert_equal %w[system user assistant system], chat.map { |message| message[:role] }
      openai = client.send(:build_context_parts, "OpenAI", messages, [])
      assert_equal "Base rules", openai[:instructions]
      assert_equal %w[user assistant system], openai[:input].map { |message| message[:role] }
      assert_equal [{ type: "input_text", text: turn.system }], openai[:input].last[:content]
      anthropic = client.send(:anthropic_payload, messages, [])
      assert_includes JSON.generate(anthropic[:system]), turn.system
      refute_includes JSON.generate(anthropic[:messages]), turn.system
      gemini = client.send(:gemini_payload, messages, [])
      assert_includes JSON.generate(gemini[:systemInstruction]), turn.system
      refute_includes JSON.generate(gemini[:contents]), turn.system
    end
    refute_includes JSON.generate(client.send(:chat_messages, conversation.context_messages)), turn.system
    refute_includes JSON.generate(client.send(:codex_payload, conversation.context_messages, [])), turn.system
  end

  def test_ordered_instruction_stays_before_tool_continuations_and_expires
    client = Kward::Client.new(api_key: nil, openai_access_token: "test-token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("Hi")
    conversation.append_assistant("Hello")
    first = request("Describe this message")
    conversation.with_system_turn(first) do
      conversation.append_system_turn(first)
      call = { "id" => "call_1", "type" => "function", "function" => { "name" => "read_file", "arguments" => "{}" } }
      conversation.append_assistant({ "role" => "assistant", "content" => nil, "tool_calls" => [call] })
      conversation.append_tool(tool_call_id: "call_1", name: "read_file", content: "Result")
      input = client.send(:codex_payload, conversation.context_messages, [])[:input]
      assert_equal ["user", "assistant", "developer", "function_call", "function_call_output"], input.map { |item| item[:role] || item[:type] }
      assert_equal first.system, input[2][:content].first[:text]
    end
    second = request("Quak like a duck!")
    conversation.with_system_turn(second) do
      conversation.append_system_turn(second)
      payload = client.send(:codex_payload, conversation.context_messages, [])
      assert_equal "developer", payload[:input].last[:role]
      assert_equal second.system, payload[:input].last[:content].first[:text]
      refute_includes JSON.generate(payload), first.system
      conversation.compact!("Previous exchange", compaction_summary: true)
      payload = client.send(:codex_payload, conversation.context_messages, [])
      assert_equal %w[assistant developer], payload[:input].map { |item| item[:role] }
      assert_equal second.system, payload[:input].last[:content].first[:text]
    end
    refute_includes JSON.generate(client.send(:codex_payload, conversation.context_messages, [])), second.system
  end

  def test_providers_requiring_dialogue_reject_system_only_requests
    client = Kward::Client.new(api_key: nil, openai_access_token: "test-token", oauth: FakeOAuth.new(nil), config_path: "missing_kward_config.json")
    messages = [{ role: "system", content: "Answer now" }]
    [:anthropic_payload, :gemini_payload].each do |method|
      error = assert_raises(ArgumentError) { client.send(method, messages, []) }
      assert_includes error.message, "system-only turn is unavailable"
    end
    payload = client.send(:codex_payload, messages, [])
    assert_equal "Answer now", payload[:instructions]
    assert_empty payload[:input]
  end

  def test_session_reload_clone_and_export_preserve_history_without_reactivation
    Dir.mktmpdir do |dir|
      store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
      session = store.create
      conversation = Kward::Conversation.new(system_message: nil)
      session.attach(conversation)
      turn = request("Saved scoped instructions")
      agent = Kward::Agent.new(client: RecordingClient.new(["Answer"]), conversation: conversation)
      agent.ask(turn)
      _loaded_session, restored = store.load(session.path)
      _cloned_session, cloned = store.create_independent_from_messages(restored.messages)
      [restored, cloned].each do |history|
        record = history.messages.first
        metadata = record[:plugin_system_turn] || record["plugin_system_turn"]
        assert_equal turn.system, metadata[:system] || metadata["system"]
        refute_includes JSON.generate(history.context_messages), turn.system
        assert_includes Kward::MarkdownTranscript.new(history).render, turn.to_s
      end
    end
  end

  def test_turn_start_hook_can_deny_a_system_turn
    hooks = Kward::Hooks::Manager.new
    hooks.register("turn_start", id: "deny") { Kward::Hooks::Decision.deny("Not allowed") }
    client = RecordingClient.new([])
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Kward::Agent.new(client: client, conversation: conversation, hook_manager: hooks)
    assert_equal "Declined: Not allowed", agent.ask(request)
    assert_empty client.seen_messages
    assert_empty conversation.messages
    assert_empty conversation.context_messages
  end

  def test_serialized_history_does_not_reactivate_instructions_or_feed_compaction
    turn = request("Never persist this as an active instruction")
    messages = JSON.parse(JSON.generate([turn.history_message]))
    restored = Kward::Conversation.new(system_message: nil, messages: messages)
    assert_equal turn.to_s, restored.messages.first["display_content"]
    refute_includes JSON.generate(restored.context_messages), turn.system
    serialized = Kward::Compaction::ConversationSerializer.new.serialize(restored.messages)
    refute_includes serialized, turn.system
  end
end
