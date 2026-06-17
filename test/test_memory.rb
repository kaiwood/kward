require_relative "test_helper"
require_relative "../lib/kward/memory/manager"

class MemoryManagerTest < KwardTestCase
  def setup
    @dir = Dir.mktmpdir
    @manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl")
    )
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_memory_is_disabled_by_default_and_enable_is_explicit
    refute @manager.enabled?

    @manager.enable

    assert @manager.enabled?
    assert File.exist?(File.join(@dir, "memory", "core.json"))
    assert File.exist?(File.join(@dir, "memory", "soft.jsonl"))
    assert_equal "enable", jsonl_records(File.join(@dir, "memory", "events.jsonl")).first["type"]
  end

  def test_auto_summary_is_disabled_by_default_and_can_be_toggled
    refute @manager.auto_summary_enabled?

    @manager.auto_summary_enable

    assert @manager.auto_summary_enabled?
    assert_equal true, JSON.parse(File.read(File.join(@dir, "config.json"))).dig("memory", "auto_summary")

    @manager.auto_summary_disable

    refute @manager.auto_summary_enabled?
    refute JSON.parse(File.read(File.join(@dir, "config.json"))).fetch("memory").key?("auto_summary")
    assert_equal ["auto_summary_enable", "auto_summary_disable"], jsonl_records(File.join(@dir, "memory", "events.jsonl")).map { |event| event["type"] }
  end

  def test_adds_core_and_soft_memories_separately
    core = @manager.add_core("Prefer small focused patches", tags: ["workflow"])
    soft = @manager.add_soft("User usually asks for tests", scope: "workspace:/tmp/kward", tags: ["workflow"])

    memories = @manager.list
    assert_equal core["id"], memories["core"].first["id"]
    assert_equal soft["id"], memories["soft"].first["id"]
    assert_equal "explicit_user_instruction", core["source"]
    assert_equal "manual", soft["source"]
  end

  def test_add_soft_reuses_existing_active_memory_for_same_scope
    first = @manager.add_soft("The user prefers TypeScript", scope: "workspace:#{@dir}")
    second = @manager.add_soft("User prefers typescript", scope: "workspace:#{@dir}")

    assert_equal first["id"], second["id"]
    assert_equal [first["id"]], @manager.list["soft"].map { |memory| memory["id"] }
  end

  def test_memory_list_hides_duplicate_soft_records_already_on_disk
    first = @manager.add_soft("The user prefers using Tool as the output label", scope: "workspace:#{File.realpath(@dir)}")
    duplicate = @manager.add_soft("The user prefers Tool as the output label", scope: "workspace:/tmp/other")
    records = jsonl_records(File.join(@dir, "memory", "soft.jsonl"))
    records << first.merge("id" => "soft_999", "text" => "The user prefers Tool as output label")
    File.write(File.join(@dir, "memory", "soft.jsonl"), records.map { |record| JSON.generate(record) }.join("\n") + "\n")

    hierarchy = @manager.hierarchy(workspace_root: @dir)

    assert_equal [first["id"]], hierarchy["workspace_soft"].map { |memory| memory["id"] }
    assert_equal [first["id"], duplicate["id"]], @manager.list["soft"].map { |memory| memory["id"] }
  end

  def test_retrieval_is_disabled_until_enabled
    @manager.add_core("Always mention tests")

    retrieval = @manager.retrieve_relevant(input: "tests", workspace_root: @dir)

    refute retrieval["enabled"]
    assert_empty retrieval["core"]
  end

  def test_retrieval_prefers_core_and_explains_soft_relevance
    @manager.enable
    @manager.add_core("Always keep changes inspectable")
    soft = @manager.add_soft("User prefers minitest workflow", scope: "workspace:#{File.realpath(@dir)}", tags: ["workflow"])

    retrieval = @manager.retrieve_relevant(input: "Please add minitest coverage", workspace_root: @dir)

    assert_equal ["core_001"], retrieval["core"].map { |item| item["id"] }
    assert_equal [soft["id"]], retrieval["soft"].map { |item| item["id"] }
    reason = retrieval["reasons"].find { |item| item["id"] == soft["id"] }
    assert_includes reason["reasons"].join(" "), "text overlap"
    assert_includes @manager.memory_block(retrieval), "Soft memories are contextual hints"
  end

  def test_retrieval_ranks_global_core_before_workspace_core
    @manager.enable
    workspace_core = @manager.add_core("Use workspace workflow", scope: "workspace:#{File.realpath(@dir)}")
    global_core = @manager.add_core("Use global workflow")

    retrieval = @manager.retrieve_relevant(input: "workflow", workspace_root: @dir)

    assert_equal [global_core["id"], workspace_core["id"]], retrieval["core"].map { |item| item["id"] }
    block = @manager.memory_block(retrieval)
    assert_operator block.index("Global Core Memories:"), :<, block.index("Workspace Core Memories:")
  end

  def test_hierarchy_only_returns_current_workspace_stages
    global_core = @manager.add_core("Use global workflow")
    workspace_core = @manager.add_core("Use workspace workflow", scope: "workspace:#{File.realpath(@dir)}")
    other_core = @manager.add_core("Use other workflow", scope: "workspace:/tmp/other")
    workspace_soft = @manager.add_soft("User prefers minitest workflow", scope: "workspace:#{File.realpath(@dir)}", tags: ["workflow"])
    other_soft = @manager.add_soft("Other workspace uses rspec", scope: "workspace:/tmp/other", tags: ["workflow"])

    hierarchy = @manager.hierarchy(workspace_root: @dir)

    assert_equal [global_core["id"]], hierarchy["global_core"].map { |item| item["id"] }
    assert_equal [workspace_core["id"]], hierarchy["workspace_core"].map { |item| item["id"] }
    assert_equal [workspace_soft["id"]], hierarchy["workspace_soft"].map { |item| item["id"] }
    refute_includes hierarchy.values.flatten.map { |item| item["id"] }, other_core["id"]
    refute_includes hierarchy.values.flatten.map { |item| item["id"] }, other_soft["id"]
  end

  def test_retrieval_requires_soft_memory_text_or_tag_overlap
    @manager.enable
    @manager.add_soft("User prefers minitest workflow", scope: "workspace:#{File.realpath(@dir)}", tags: ["workflow"])

    retrieval = @manager.retrieve_relevant(input: "Please inspect authentication", workspace_root: @dir)

    assert_empty retrieval["soft"]
  end

  def test_retrieval_updates_soft_memory_hits_and_last_seen_at
    created_at = Time.utc(2024, 1, 1, 12, 0, 0)
    manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl"),
      now: created_at
    )
    manager.enable
    soft = manager.add_soft("User prefers minitest workflow", scope: "workspace:#{File.realpath(@dir)}", tags: ["workflow"])

    retrieval_manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl"),
      now: created_at + 60
    )
    retrieval_manager.retrieve_relevant(input: "minitest coverage", workspace_root: @dir)

    reloaded = retrieval_manager.list["soft"].find { |item| item["id"] == soft["id"] }
    assert_equal 1, reloaded["hits"]
    assert_equal (created_at + 60).utc.iso8601(3), reloaded["last_seen_at"]
  end

  def test_promote_soft_to_core_forgets_soft_record
    soft = @manager.add_soft("Use Minitest for this project")

    core = @manager.promote_memory(soft["id"])

    assert_equal "Use Minitest for this project", core["text"]
    assert_empty @manager.list["soft"]
    forgotten = @manager.list(include_inactive: true)["soft"].first
    assert_equal "forgotten", forgotten["status"]
    assert_equal "[forgotten]", forgotten["text"]
  end

  def test_promote_workspace_core_to_global_core
    core = @manager.add_core("Use Minitest for this project", scope: "workspace:#{File.realpath(@dir)}")

    promoted = @manager.promote_memory(core["id"])

    assert_equal core["id"], promoted["id"]
    assert_equal "global", promoted["scope"]
    assert_equal "global", @manager.list["core"].find { |item| item["id"] == core["id"] }["scope"]
  end

  def test_relax_global_core_to_current_workspace_core
    core = @manager.add_core("Use Minitest for this project")

    relaxed = @manager.relax_core(core["id"], workspace_root: @dir)

    assert_equal core["id"], relaxed["id"]
    assert_equal "workspace:#{File.realpath(@dir)}", relaxed["scope"]
    assert_equal "workspace:#{File.realpath(@dir)}", @manager.list["core"].find { |item| item["id"] == core["id"] }["scope"]
  end

  def test_forget_soft_memory_redacts_stored_text_and_tags
    soft = @manager.add_soft("The user prefers private details", tags: ["private"])

    assert @manager.forget_memory(soft["id"])

    forgotten = @manager.list(include_inactive: true)["soft"].first
    assert_equal "forgotten", forgotten["status"]
    assert_equal "[forgotten]", forgotten["text"]
    assert_empty forgotten["tags"]
    assert_equal 0.0, forgotten["confidence"]
  end

  def test_inferred_memory_requires_personal_or_explicit_memory_signal
    # Mock client returns the input unchanged (simulating no summarization change)
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |messages, **opts|
      # Extract the input text from the reformulate prompt
      text = messages.last[:content].to_s.gsub(/^Reformulate this as a memory statement: /, "")
      { "content" => text }
    end

    records = @manager.infer_soft_from_text(<<~TEXT, workspace_root: @dir, client: mock_client)
      Prefer evidence from code, tests, logs, docs, and reproducible commands
      Use concise sections as useful:
      Here is an important information: The Captain likes eating steak.
    TEXT

    # The extraction still works, and the mock preserves the original text
    assert_equal ["The Captain likes eating steak"], records.map { |record| record["text"] }
  end

  def test_refuses_unsafe_inferred_soft_memory
    assert_raises(ArgumentError) do
      @manager.add_soft("The user loves me", source: "inferred")
    end
  end

  # Text normalization tests (TDD)
  def test_normalizes_verbose_preamble_from_memory_text
    core = @manager.add_core("But first we always need to remember that we are using TDD from now on")
    assert_equal "Use TDD from now on", core["text"]
  end

  def test_normalizes_remember_that_preamble
    core = @manager.add_core("Remember that we should prefer small focused patches")
    assert_equal "Prefer small focused patches", core["text"]
  end

  def test_normalizes_please_remember_preamble
    core = @manager.add_core("Please remember to test everything thoroughly")
    assert_equal "Test everything thoroughly", core["text"]
  end

  def test_normalizes_note_that_preamble
    core = @manager.add_core("Note that the user prefers minitest over rspec")
    assert_equal "The user prefers minitest over rspec", core["text"]
  end

  def test_normalizes_soft_memory_text
    soft = @manager.add_soft("But first we always need to remember that testing is important")
    assert_equal "Testing is important", soft["text"]
  end

  def test_preserves_text_without_preamble
    core = @manager.add_core("Always use defensive coding")
    assert_equal "Always use defensive coding", core["text"]
  end

  def test_preserves_text_with_unrecognized_preamble
    core = @manager.add_core("Specifically we should validate all inputs")
    assert_equal "Specifically we should validate all inputs", core["text"]
  end

  def test_strips_workspace_context_prefix
    core = @manager.add_core("[workspace:/Users/kwood/Repositories/github.com/kaiwood/kward] Use TDD from now on")
    assert_equal "Use TDD from now on", core["text"]
  end

  def test_summarize_text_uses_llm_when_client_provided
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |messages, **opts|
      # Return a response with content that reformulates the input
      if messages.any? { |m| m[:content].to_s.include?("steak") }
        { "content" => "The user likes eating steak" }
      else
        { "content" => messages.last[:content].to_s.gsub(/^Reformulate this as a memory statement: /, "") }
      end
    end

    result = @manager.summarize_text("I like to eat the most important meal today: steak", client: mock_client)
    assert_equal "The user likes eating steak", result
  end

  def test_summarize_text_returns_original_on_llm_failure
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) { |*| raise StandardError, "LLM failed" }

    result = @manager.summarize_text("I like steak", client: mock_client)
    assert_equal "I like steak", result
  end

  def test_infer_soft_from_text_uses_summarized_text
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |messages, **opts|
      text = messages.last[:content].to_s.gsub(/^Reformulate this as a memory statement: /, "")
      { "content" => "The captain likes eating steak" }
    end

    records = @manager.infer_soft_from_text(
      "I like to eat the most important meal today: steak",
      workspace_root: @dir,
      client: mock_client
    )

    assert_equal 1, records.length
    assert_equal "The user likes eating steak", records.first["text"]
  end

  def test_summarize_text_passes_through_when_llm_not_available
    # Test that summarize_text falls back to original text when LLM is not available
    original_text = "I like steak"
    # Force should_use_llm_summarization? to return false by creating manager without default_client
    manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl")
    )
    # Override the check to simulate no credentials
    manager.define_singleton_method(:should_use_llm_summarization?) { false }

    result = manager.summarize_text(original_text)
    assert_equal original_text, result
  end

  def test_infer_soft_from_text_skips_duplicates_in_existing_texts
    # Disable LLM summarization to test exact duplicate detection
    manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl")
    )
    manager.define_singleton_method(:should_use_llm_summarization?) { false }

    records = manager.infer_soft_from_text(
      "I like steak",
      workspace_root: @dir,
      existing_texts: ["I like steak"]
    )
    assert_empty records
  end

  def test_for_config_dir_uses_standard_memory_paths
    manager = Kward::Memory::Manager.for_config_dir(@dir)

    assert_equal File.join(@dir, "memory", "core.json"), manager.paths["core"]
    assert_equal File.join(@dir, "memory", "soft.jsonl"), manager.paths["soft"]
    assert_equal File.join(@dir, "memory", "events.jsonl"), manager.paths["events"]
  end

  def test_summarize_conversation_persists_session_memories_from_user_messages
    conversation = Kward::Conversation.new(messages: [{ role: "user", content: "I like steak" }], workspace_root: @dir, session_memories: [])
    @manager.define_singleton_method(:should_use_llm_summarization?) { false }

    records = @manager.summarize_conversation(conversation)

    assert_equal ["The user likes steak"], records.map { |record| record["text"] }
    assert_equal [{ "id" => "soft_001", "text" => "The user likes steak", "scope" => "workspace:#{File.realpath(@dir)}", "tags" => ["workflow"] }], conversation.session_memories
  end

  def test_infer_soft_from_text_skips_duplicates_in_existing_soft_memories
    # Disable LLM summarization
    manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl")
    )
    manager.define_singleton_method(:should_use_llm_summarization?) { false }

    # Add first memory
    manager.add_soft("I like steak", scope: "workspace:#{@dir}")

    # Try to add duplicate
    records = manager.infer_soft_from_text(
      "I like steak",
      workspace_root: @dir
    )

    assert_empty records
    assert_equal 1, manager.list["soft"].length
  end

  def test_infer_soft_from_text_skips_duplicates_after_normalization
    # Disable LLM summarization
    manager = Kward::Memory::Manager.new(
      config_path: File.join(@dir, "config.json"),
      core_path: File.join(@dir, "memory", "core.json"),
      soft_path: File.join(@dir, "memory", "soft.jsonl"),
      events_path: File.join(@dir, "memory", "events.jsonl")
    )
    manager.define_singleton_method(:should_use_llm_summarization?) { false }

    # Add first memory
    manager.add_soft("I like steak", scope: "workspace:#{@dir}")

    # Try to add with slight variation (should normalize to same)
    records = manager.infer_soft_from_text(
      "I like  steak",
      workspace_root: @dir
    )

    assert_empty records
    assert_equal 1, manager.list["soft"].length
  end

  def test_inferred_memory_canonicalizes_personal_subject_to_user
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, **_opts|
      { "content" => "The teammate prefers concise and practical answers" }
    end

    records = @manager.infer_soft_from_text(
      "I usually prefer concise and practical answers.",
      workspace_root: @dir,
      client: mock_client
    )

    assert_equal ["The user prefers concise and practical answers"], records.map { |record| record["text"] }
  end

  def test_inferred_memory_canonicalizes_first_person_with_frequency_adverb
    @manager.define_singleton_method(:should_use_llm_summarization?) { false }

    records = @manager.infer_soft_from_text(
      "I usually prefer concise and practical answers.",
      workspace_root: @dir
    )

    assert_equal ["The user usually prefers concise and practical answers"], records.map { |record| record["text"] }
  end

  def test_infer_soft_from_text_skips_auto_summary_duplicate_with_not_using_variant
    mock_client = Object.new
    responses = [
      "The user prefers not using Assistant> as a prefix",
      "The user prefers not to use Assistant> as a prefix"
    ]
    mock_client.define_singleton_method(:chat) do |_messages, **_opts|
      { "content" => responses.shift }
    end

    first = @manager.infer_soft_from_text(
      "I prefer not using Assistant> as a prefix",
      workspace_root: @dir,
      client: mock_client
    )
    second = @manager.infer_soft_from_text(
      "I prefer not to use Assistant> as a prefix",
      workspace_root: @dir,
      client: mock_client
    )

    assert_equal 1, first.length
    assert_empty second
    assert_equal ["The user prefers not using Assistant> as a prefix"], @manager.list["soft"].map { |memory| memory["text"] }
  end

  def test_infer_soft_from_text_skips_similar_duplicate_memories
    mock_client = Object.new
    responses = [
      "The user prefers starting directly with refactor/cleanup",
      "The user prefers directly starting with refactor/cleanup"
    ]
    mock_client.define_singleton_method(:chat) do |_messages, **_opts|
      { "content" => responses.shift }
    end

    first = @manager.infer_soft_from_text(
      "I prefer starting directly with refactor/cleanup",
      workspace_root: @dir,
      client: mock_client
    )
    second = @manager.infer_soft_from_text(
      "I prefer directly starting with refactor/cleanup",
      workspace_root: @dir,
      client: mock_client
    )

    assert_equal 1, first.length
    assert_empty second
    assert_equal 1, @manager.list["soft"].length
  end
end
