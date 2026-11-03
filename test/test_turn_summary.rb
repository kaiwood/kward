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

  def test_detailed_mode_aggregates_cache_and_reasoning_without_changing_compact_mode
    stats = Kward::TurnSummary.new
    [
      { "input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120, "cache_read_tokens" => 90, "cache_write_tokens" => 10, "reasoning_tokens" => 15 },
      { "input_tokens" => 900, "output_tokens" => 80, "total_tokens" => 980, "cache_read_tokens" => 300, "cache_write_tokens" => 50, "reasoning_tokens" => 35 }
    ].each do |usage|
      stats.model_request
      stats.record("usage" => usage)
    end
    summary = stats.finish(status: "completed", elapsed_ms: 1_500)
    text = Kward::TurnSummaryFormatter.render(summary, mode: "detailed")
    assert_equal "Input 1.0k · Cached 390 (39%) · Output 100 · Reasoning 50 · Cache writes 60", text.lines.last.chomp
    assert_equal 1_100, summary.dig("usage", "total_tokens")
    refute summary["usage"].key?("partial_fields")
    assert_equal "Completed · 1.5s · 1.1k tokens · 0 tool calls", Kward::TurnSummaryFormatter.render(summary)
  end

  def test_detailed_mode_marks_incomplete_fields_and_omits_cache_percentage
    stats = Kward::TurnSummary.new
    stats.model_request
    stats.record("usage" => { "input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120, "cache_read_tokens" => 90, "reasoning_tokens" => 15 })
    stats.model_request
    stats.record(response("done", total: 12))
    summary = stats.finish(status: "completed", elapsed_ms: 10)

    assert_equal "complete", summary["usageStatus"]
    assert_equal %w[cache_read_tokens reasoning_tokens], summary["usage"]["partial_fields"]
    text = Kward::TurnSummaryFormatter.render(summary, mode: "detailed")
    assert_includes text, "Cached 90 (partial)"
    assert_includes text, "Reasoning 15 (partial)"
    refute_includes text, "%"
    refute_includes text, "Cache writes"
  end

  def test_detailed_cache_rate_requires_input_coverage_as_well_as_cache_coverage
    stats = Kward::TurnSummary.new
    [
      { "input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120, "cache_read_tokens" => 90 },
      { "output_tokens" => 20, "total_tokens" => 120, "cache_read_tokens" => 10 }
    ].each do |usage|
      stats.model_request
      stats.record("usage" => usage)
    end
    summary = stats.finish(status: "completed", elapsed_ms: 10)
    assert_equal ["input_tokens"], summary["usage"]["partial_fields"]
    text = Kward::TurnSummaryFormatter.render(summary, mode: "detailed")
    assert_includes text, "Input 100 (partial)"
    assert_includes text, "Cached 100"
    refute_includes text, "%"
  end

  def test_detailed_mode_preserves_zero_but_omits_unknown_details_and_undefined_rates
    summary = sample_summary
    text = Kward::TurnSummaryFormatter.render(summary, mode: "detailed")
    refute_match(/Cached|Reasoning|Cache writes/, text)

    summary["usage"].merge!("cache_read_tokens" => 0, "cache_write_tokens" => 0, "reasoning_tokens" => 0)
    text = Kward::TurnSummaryFormatter.render(summary, mode: "detailed")
    assert_includes text, "Cached 0 (0%)"
    assert_includes text, "Reasoning 0"
    assert_includes text, "Cache writes 0"
    summary["usage"]["input_tokens"] = 0
    refute_includes Kward::TurnSummaryFormatter.render(summary, mode: "detailed"), "%"
    summary["usage"]["input_tokens"] = 10
    summary["usageStatus"] = "partial"
    refute_includes Kward::TurnSummaryFormatter.render(summary, mode: "detailed"), "%"
  end

  def test_detailed_stats_survive_persistence_rpc_and_exports
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("transcript" => { "turn_stats" => "detailed" }))
      with_env("KWARD_CONFIG_PATH" => config_path) do
        store = Kward::SessionStore.new(config_dir: dir, cwd: Dir.pwd)
        conversation = Kward::Conversation.new(system_message: nil)
        session = store.create_from_conversation(conversation)
        message = response("done", total: 12)
        message["usage"].merge!("cache_read_tokens" => 8, "cache_write_tokens" => 2, "reasoning_tokens" => 1)
        Kward::Agent.new(client: FakeClient.new([message]), conversation: conversation).ask("hello")
        loaded = store.load(session.path).last
        summary = Kward::RPC::TranscriptNormalizer.new(loaded.messages).normalize.last[:turnSummary]
        assert_equal 8, summary.dig("usage", "cache_read_tokens")
        assert_equal 2, summary.dig("usage", "cache_write_tokens")
        assert_equal 1, summary.dig("usage", "reasoning_tokens")
        reply = response("done", total: 12).merge("usage" => summary["usage"])
        cli = Kward::CLI.new(argv: [], client: FakeClient.new([reply]))
        output = cli.one_shot("hello")
        assert_includes output, "Cached 8 (80%)"
        assert_includes output, "Reasoning 1"
        assert_includes output, "Cache writes 2"
        %w[markdown html].each do |format|
          export = Kward::TranscriptExport.content(loaded, format: format)
          assert_includes export, "Cached 8 (80%)"
          assert_includes export, "Reasoning 1"
          assert_includes export, "Cache writes 2"
        end
      end
    end
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
