require_relative "test_helper"
require_relative "../lib/kward/scouts"

class TestScouts < KwardTestCase
  def test_store_persists_and_lists_scouts
    Dir.mktmpdir do |dir|
      store = Kward::Scouts::Store.new(path: File.join(dir, "scouts.json"))
      scout = store.create(prompt: "Explore better RPC docs", workspace_root: dir)

      assert_equal "queued", scout["status"]
      assert_equal "Explore better RPC docs", scout["title"]

      restored = Kward::Scouts::Store.new(path: store.path).find(scout.fetch("id"))
      assert_equal scout.fetch("id"), restored.fetch("id")
      assert_equal Kward::ConfigFiles.canonical_workspace_root(dir), restored.fetch("workspace_root")
    end
  end

  def test_read_only_registry_hides_write_tools_for_scouts
    registry = Kward::ToolRegistry.new(allowed_tool_names: Kward::Scouts::Runner::READ_ONLY_TOOLS)
    names = registry.schemas.map { |schema| schema.fetch(:function).fetch(:name) }

    assert_includes names, "read_file"
    assert_includes names, "list_directory"
    refute_includes names, "write_file"
    refute_includes names, "edit_file"
    refute_includes names, "run_shell_command"
  end

  def test_runner_writes_ready_report
    Dir.mktmpdir do |dir|
      store = Kward::Scouts::Store.new(path: File.join(dir, "scouts.json"))
      client = FakeClient.new([{ "role" => "assistant", "content" => "# Scout Report\nReady." }])
      runner = Kward::Scouts::Runner.new(store: store, client: client, workspace_root: dir)

      scout = runner.start("Plan a tiny change")
      wait_until(timeout: 1) { store.find(scout.fetch("id"))["status"] == "ready" }

      saved = store.find(scout.fetch("id"))
      assert_equal "ready", saved["status"]
      assert_equal "# Scout Report\nReady.", saved["report"]
    end
  end
end
