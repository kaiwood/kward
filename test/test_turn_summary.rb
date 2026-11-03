require_relative "test_helper"
require_relative "../lib/kward/turn_summary"
require_relative "../lib/kward/transcripts/turn_summary_formatter"
require_relative "../lib/kward/transcripts/transcript_export"
require_relative "../lib/kward/rpc/transcript_normalizer"

class TestTurnSummary < KwardTestCase
  class ToolRegistry
    def schemas
      []
    end

    def dispatch(call, conversation, **)
      conversation.append_tool(tool_call_id: call["id"], name: "test_tool", content: "result")
      "result"
    end
  end

  def test_agent_aggregates_all_requests_and_excludes_stats_from_model_context
    conversation = Kward::Conversation.new(system_message: nil)
    call = { "id" => "call_1", "function" => { "name" => "test_tool", "arguments" => "{}" } }
    client = FakeClient.new([
      response("checking", total: 12).merge("tool_calls" => [call]),
      response("done", total: 24),
      response("next", total: 6)
    ])
    agent = Kward::Agent.new(client: client, conversation: conversation, tool_registry: ToolRegistry.new)
    events = []

    assert_equal "done", agent.ask("hello") { |event| events << event }
    summary = events.last.summary
    assert_instance_of Kward::Events::TurnSummary, events.last
    assert_equal 1, events.grep(Kward::Events::TurnSummary).length
    assert_equal "completed", summary["status"]
    assert_equal "complete", summary["usageStatus"]
    assert_equal 36, summary.dig("usage", "total_tokens")
    assert_equal 2, summary["modelRequests"]
    assert_equal 1, summary["toolCalls"]
    assert_operator summary["elapsedMs"], :>=, 0
    assert_equal summary, conversation.messages.last["turn_summary"]
    refute conversation.context_messages.any? { |message| message.key?("turn_summary") }
    refute_includes Kward::Compaction::ConversationSerializer.new.serialize(conversation.messages), "elapsedMs"

    agent.ask("again")
    assert_equal 6, conversation.messages.last.dig("turn_summary", "usage", "total_tokens")
    assert_equal 1, conversation.messages.last.dig("turn_summary", "modelRequests")
    assert_equal 0, conversation.messages.last.dig("turn_summary", "toolCalls")
  end

  def test_missing_and_zero_usage_are_distinct_and_partial_usage_is_marked
    stats = Kward::TurnSummary.new
    stats.model_request
    stats.record("content" => "no usage")
    assert_equal "unavailable", stats.finish(status: "completed", elapsed_ms: 10)["usageStatus"]
    assert_nil stats.finish(status: "completed", elapsed_ms: 10)["usage"]

    stats.model_request
    stats.record("usage" => { "total_tokens" => 0, "estimated" => true })
    summary = stats.finish(status: "completed", elapsed_ms: 10)
    assert_equal "partial", summary["usageStatus"]
    assert_equal 0, summary.dig("usage", "total_tokens")
    assert_equal true, summary.dig("usage", "estimated")
    assert_includes Kward::TurnSummaryFormatter.render(summary), "~0 tokens (partial)"
  end

  def test_retries_do_not_claim_complete_accounting
    stats = Kward::TurnSummary.new
    stats.model_request
    stats.retry
    stats.record(response("done", total: 12))
    assert_equal "partial", stats.finish(status: "completed", elapsed_ms: 20)["usageStatus"]
  end

  def test_failure_and_cancellation_still_emit_and_persist_a_summary
    [RuntimeError.new("offline"), Kward::Cancellation::CancelledError.new("cancelled")].each do |error|
      client = Object.new
      client.define_singleton_method(:chat) { |*, **| raise error }
      conversation = Kward::Conversation.new(system_message: nil)
      agent = Kward::Agent.new(client: client, conversation: conversation, tool_registry: ToolRegistry.new)
      events = []

      assert_raises(error.class) { agent.ask("hello") { |event| events << event } }
      summary = events.last.summary
      assert_equal(error.is_a?(Kward::Cancellation::CancelledError) ? "canceled" : "failed", summary["status"])
      assert_equal "unavailable", summary["usageStatus"]
      assert_equal 1, summary["modelRequests"]
      assert_equal summary, conversation.messages.last["turn_summary"]
      assert_equal "user", conversation.messages.last[:role]
    end
  end

  def test_failure_after_a_reported_request_keeps_partial_usage
    call = { "id" => "call_1", "function" => { "name" => "test_tool", "arguments" => "{}" } }
    replies = [response("checking", total: 12).merge("tool_calls" => [call])]
    client = Object.new
    client.define_singleton_method(:chat) { |*, **| replies.shift || raise("offline") }
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Kward::Agent.new(client: client, conversation: conversation, tool_registry: ToolRegistry.new)

    assert_raises(RuntimeError) { agent.ask("hello") }
    summary = conversation.messages.last["turn_summary"]
    assert_equal "failed", summary["status"]
    assert_equal "partial", summary["usageStatus"]
    assert_equal 12, summary.dig("usage", "total_tokens")
    assert_equal 2, summary["modelRequests"]
  end

  def test_pre_cancelled_turn_does_not_overwrite_previous_summary
    conversation = Kward::Conversation.new(system_message: nil)
    agent = Kward::Agent.new(client: FakeClient.new([response("done", total: 12)]), conversation: conversation)
    agent.ask("hello")
    previous = conversation.messages.last["turn_summary"]
    cancellation = Kward::Cancellation.new
    cancellation.cancel!
    events = []

    assert_raises(Kward::Cancellation::CancelledError) do
      agent.ask("not started", cancellation: cancellation) { |event| events << event }
    end
    assert_empty events
    assert_same previous, conversation.messages.last["turn_summary"]
  end

  def test_summary_survives_reload_clone_and_branch_selection
    Dir.mktmpdir do |dir|
      store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
      conversation = Kward::Conversation.new(system_message: nil)
      session = store.create_from_conversation(conversation)
      conversation.append_user("hello")
      user_id = conversation.messages.last["id"]
      conversation.append_assistant("done")
      answer_id = conversation.messages.last["id"]
      summary = sample_summary
      conversation.finish_turn(summary)
      assert_equal answer_id, session.leaf_id

      loaded_session, loaded = store.load(session.path)
      assert_equal summary, loaded.messages.last["turn_summary"]
      assert_equal summary, store.session_entry(session.path, answer_id)["message"]["turn_summary"]
      records = File.readlines(session.path).map { |line| JSON.parse(line) }
      summaries = records.select { |record| record["type"] == "turn_summary" }
      assert_equal 1, summaries.length
      assert_equal answer_id, summaries.first["targetId"]
      refute records.find { |record| record["id"] == answer_id }["message"].key?("turn_summary")
      assert_equal summary, Kward::RPC::TranscriptNormalizer.new(loaded.messages).normalize.last[:turnSummary]
      assert_includes Kward::TranscriptExport.content(loaded), "Completed · 1.5s · 12 tokens"
      assert_includes Kward::TranscriptExport.content(loaded, format: "html"), "Completed · 1.5s · 12 tokens"

      clone, = store.create_independent_from_conversation(loaded)
      assert_equal summary, store.load(clone.path).last.messages.last["turn_summary"]
      loaded_session.branch(user_id)
      refute store.load(session.path).last.messages.any? { |message| message["turn_summary"] }
      loaded_session.branch(answer_id)
      assert_equal summary, store.load(session.path).last.messages.last["turn_summary"]
    end
  end

  def test_off_hides_exports_but_preserves_data_and_filter_stays_answer_only
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("transcript" => { "turn_stats" => "off" }))
      with_env("KWARD_CONFIG_PATH" => config_path) do
        conversation = Kward::Conversation.new(system_message: nil)
        agent = Kward::Agent.new(client: FakeClient.new([response("done", total: 12)]), conversation: conversation)
        agent.ask("hello")
        assert_equal 12, conversation.messages.last.dig("turn_summary", "usage", "total_tokens")
        refute_includes Kward::TranscriptExport.content(conversation), "Completed"
        refute_includes Kward::TranscriptExport.content(conversation, format: "html"), "Completed"
      end
      File.write(config_path, JSON.dump("transcript" => { "turn_stats" => "detailed" }))
      with_env("KWARD_CONFIG_PATH" => config_path) do
        cli = Kward::CLI.new(argv: [], client: FakeClient.new([response("answer only", total: 12)]))
        output, error = capture_io { assert_equal "answer only", cli.one_shot("hello", filter: true) }
        assert_empty output
        assert_empty error
      end
    end
  end

  def test_formatter_modes_and_narrow_terminal
    summary = sample_summary
    assert_equal "Completed · 1.5s · 12 tokens · 0 tool calls", Kward::TurnSummaryFormatter.render(summary)
    assert_equal "", Kward::TurnSummaryFormatter.render(summary, mode: "off")
    assert_equal "Completed · 1.5s", Kward::TurnSummaryFormatter.render(summary, width: 20)
    assert_equal "Completed · 1.5s · 12 tokens · 1 model request · 0 tool calls\nInput 10 · Output 2", Kward::TurnSummaryFormatter.render(summary, mode: "detailed")
    assert_equal "", Kward::TurnSummaryFormatter.render(nil)
  end

  def test_display_preference_defaults_and_validation
    assert_equal "compact", Kward::ConfigFiles.transcript_turn_stats({})
    assert_equal "compact", Kward::ConfigFiles.transcript_turn_stats("transcript" => { "turn_stats" => "invalid" })
    %w[off compact detailed].each do |mode|
      assert_equal mode, Kward::ConfigFiles.transcript_turn_stats("transcript" => { "turn_stats" => mode })
    end
  end

  private

  def response(content, total:)
    { "role" => "assistant", "content" => content, "usage" => { "input_tokens" => total - 2, "output_tokens" => 2, "total_tokens" => total } }
  end

  def sample_summary
    stats = Kward::TurnSummary.new
    stats.model_request
    stats.record(response("done", total: 12))
    stats.finish(status: "completed", elapsed_ms: 1_500)
  end
end
