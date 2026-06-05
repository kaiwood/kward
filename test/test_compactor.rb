require_relative "test_helper"

class TestCompactor < KwardTestCase
  def test_compaction_uses_ruby_checkpoint_prompt_without_workspace_personality
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |workspace|
        File.write(File.join(workspace, "AGENTS.md"), "Use project rules.\n")
        File.write(File.join(config_dir, "config.json"), JSON.dump({
          "workspaces" => {
            workspace => { "system_prompt" => "Speak like a starship computer." }
          }
        }))

        with_env("KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          conversation = Kward::Conversation.new(workspace_root: workspace)
          conversation.append_user("Continue the implementation with a long enough transcript to require compaction.")
          conversation.append_assistant("ok")
          settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)
          compactor = Kward::Compactor.new(conversation: conversation, client: RecordingClient.new(["summary"]), settings: settings)
          messages = compactor.compaction_messages("focus on specs")

          system_content = messages.first[:content]
          user_content = messages.last[:content]
          assert_includes conversation.messages.first[:content], "Speak like a starship computer."
          refute_includes system_content, "Speak like a starship computer."
          assert_includes system_content, "context summarization assistant"
          assert_includes user_content, "<conversation>"
          assert_includes user_content, "## Ruby Project Context"
          assert_includes user_content, "Additional focus: focus on specs"
          refute_includes user_content, "Speak like a starship computer."
        end
      end
    end
  end

  def test_prompt_builder_wraps_previous_summary_and_uses_update_prompt
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.messages << { role: "compactionSummary", summary: "old summary", first_kept_entry_id: "message:1", details: { read_files: ["old.rb"] } }
    conversation.append_user("again with enough detail to require an updated compaction summary")
    conversation.append_assistant("new work")
    settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)
    preparation = Kward::Compaction::Preparation.new(conversation: conversation, settings: settings).call

    messages = Kward::Compaction::PromptBuilder.new.build(preparation)
    content = messages.last[:content]

    assert_includes content, "<previous-summary>\nold summary\n</previous-summary>"
    assert_includes content, "NEW conversation messages"
    refute_includes content, "Additional focus:"
  end

  def test_token_budgets_use_reserve_fraction_and_model_clamp
    settings = Kward::Compaction::Settings.new(reserve_tokens: 10_000)
    builder = Kward::Compaction::PromptBuilder.new

    assert_equal 8_000, builder.normal_summary_max_tokens(settings)
    assert_equal 5_000, builder.split_turn_max_tokens(settings)
    assert_equal 3_000, builder.normal_summary_max_tokens(settings, model_max_tokens: 3_000)
    assert_equal 2_000, builder.split_turn_max_tokens(settings, model_max_tokens: 2_000)
  end

  def test_compaction_serializer_limits_tool_results_to_two_thousand_chars
    content = ("a" * 2_000) + ("b" * 3_000)
    messages = [
      assistant_tool_call("read_file", path: "big.txt"),
      { role: "tool", tool_call_id: "call_read_file", name: "read_file", content: content }
    ]

    serialized = Kward::Compaction::ConversationSerializer.new.serialize(messages)
    tool_result = serialized.split("[Tool result read_file]: ", 2).last

    assert_equal "#{"a" * 2_000}\n...[truncated 3000 bytes]", tool_result
  end

  def test_compactor_uses_tool_result_summarizer_in_compaction_prompt
    raw_content = "raw-file-content-" * 400
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("read an old file before recent work")
    conversation.append_assistant(assistant_tool_call("read_file", path: "big.txt"))
    conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: raw_content)
    conversation.append_user("recent request")
    conversation.append_assistant("recent reply")
    settings = Kward::Compaction::Settings.new(keep_recent_tokens: 20)
    client = RecordingClient.new(["## Goal\ncontinue"])

    Kward::Compactor.new(
      conversation: conversation,
      client: client,
      settings: settings,
      tool_result_summarizer: lambda do |tool_call, content|
        args = JSON.parse(tool_call.fetch("function").fetch("arguments"))
        "read_file: #{args.fetch("path")}\n#{content.bytesize} bytes"
      end
    ).compact

    prompt = client.seen_messages.first.last[:content]
    assert_includes prompt, "[Tool result read_file]: read_file: big.txt\n#{raw_content.bytesize} bytes"
    refute_includes prompt, raw_content[0, 80]
  end

  def test_preparation_detects_nothing_and_already_compacted
    assert_raises(Kward::Compaction::NothingToCompact) do
      Kward::Compaction::Preparation.new(conversation: Kward::Conversation.new(system_message: nil)).call
    end

    conversation = Kward::Conversation.new(system_message: nil)
    conversation.messages << { role: "compactionSummary", summary: "summary" }

    assert_raises(Kward::Compaction::AlreadyCompacted) do
      Kward::Compaction::Preparation.new(conversation: conversation).call
    end
  end

  def test_cut_point_keeps_tool_result_attached_to_assistant_tool_call
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("inspect the old file and preserve this older request in summary")
    conversation.append_assistant(assistant_tool_call("read_file", path: "app/models/user.rb"))
    conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "class User\nend\n")
    conversation.append_user("continue")
    conversation.append_assistant("ok")
    settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)

    preparation = Kward::Compaction::Preparation.new(conversation: conversation, settings: settings).call

    assert_equal "message:3", preparation.first_kept_entry_id
    assert_equal ["user", "assistant", "tool"], preparation.messages_to_summarize.map { |message| message[:role] || message["role"] }
    assert_equal ["user", "assistant"], preparation.kept_messages.map { |message| message[:role] || message["role"] }
    assert_equal({ read_files: ["app/models/user.rb"], modified_files: [] }, preparation.file_ops)
  end

  def test_split_turn_extracts_prefix_without_cutting_at_tool_result
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("one huge turn")
    conversation.append_assistant("a" * 120)
    conversation.append_tool(tool_call_id: "call", name: "read_file", content: "result")
    conversation.append_assistant("suffix")
    settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)

    preparation = Kward::Compaction::Preparation.new(conversation: conversation, settings: settings).call

    assert preparation.split_turn
    assert_equal ["user", "assistant", "tool"], preparation.turn_prefix_messages.map { |message| message[:role] || message["role"] }
    assert_equal ["user", "assistant"], preparation.kept_messages.map { |message| message[:role] || message["role"] }
  end

  def test_successful_compaction_appends_summary_and_keeps_recent_messages
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("old request with enough detail to require compaction")
    conversation.append_assistant("old reply")
    conversation.append_user("recent")
    conversation.append_assistant("recent reply")
    settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)
    client = RecordingClient.new(["## Goal\ncontinue"])

    result = Kward::Compactor.new(conversation: conversation, client: client, settings: settings).compact

    assert_includes result.summary, "## Files"
    assert_equal "message:2", result.first_kept_entry_id
    assert_equal ["compactionSummary", "user", "assistant"], conversation.messages.map { |message| message[:role] || message["role"] }
    summary = conversation.messages.first
    assert_equal "message:2", summary[:first_kept_entry_id]
    assert_equal false, summary[:from_hook]
    assert_equal({ read_files: [], modified_files: [] }, summary[:details])
  end

  def test_auto_compaction_uses_last_provider_usage_plus_trailing_messages
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("short old request")
    conversation.append_assistant({
      "role" => "assistant",
      "content" => "short reply",
      "usage" => {
        "input_tokens" => 90,
        "output_tokens" => 5,
        "total_tokens" => 95,
        "estimated" => false
      }
    })
    conversation.append_user("new request")
    settings = Kward::Compaction::Settings.new(reserve_tokens: 20, keep_recent_tokens: 4)
    client = RecordingClient.new(["## Goal\ncontinue"])

    old_heuristic_tokens = Kward::Compaction::TokenEstimator.new.messages_tokens(conversation.messages)
    result = Kward::Compactor.new(conversation: conversation, client: client, settings: settings).auto_compact_if_needed(context_window: 100)

    assert_operator old_heuristic_tokens, :<, 80
    refute_nil result
    assert_operator result.tokens_before, :>, 95
    assert_equal "compactionSummary", conversation.messages.first[:role]
  end

  def test_summarizer_failure_does_not_mutate_conversation
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("old request with enough detail to require compaction")
    conversation.append_assistant("old reply")
    conversation.append_user("recent")
    settings = Kward::Compaction::Settings.new(keep_recent_tokens: 10)
    original = conversation.messages.map(&:dup)
    client = Class.new do
      def chat(_messages, tools: [])
        raise "boom"
      end
    end.new

    assert_raises(Kward::Compaction::SummarizationFailed) do
      Kward::Compactor.new(conversation: conversation, client: client, settings: settings).compact
    end
    assert_equal original, conversation.messages
  end
end
