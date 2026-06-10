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

  def test_adds_core_and_soft_memories_separately
    core = @manager.add_core("Prefer small focused patches", tags: ["workflow"])
    soft = @manager.add_soft("User usually asks for tests", scope: "workspace:/tmp/kward", tags: ["workflow"])

    memories = @manager.list
    assert_equal core["id"], memories["core"].first["id"]
    assert_equal soft["id"], memories["soft"].first["id"]
    assert_equal "explicit_user_instruction", core["source"]
    assert_equal "manual", soft["source"]
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

  def test_promote_soft_to_core_forgets_soft_record
    soft = @manager.add_soft("Use Minitest for this project")

    core = @manager.promote_soft_to_core(soft["id"])

    assert_equal "Use Minitest for this project", core["text"]
    assert_empty @manager.list["soft"]
    assert_equal "forgotten", @manager.list(include_inactive: true)["soft"].first["status"]
  end

  def test_refuses_unsafe_inferred_soft_memory
    assert_raises(ArgumentError) do
      @manager.add_soft("The user loves me", source: "inferred")
    end
  end
end
