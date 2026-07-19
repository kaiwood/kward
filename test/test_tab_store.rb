require_relative "test_helper"

class TestTabStore < KwardTestCase
  def test_save_and_load_workspace_tabs
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      store = Kward::TabStore.new(config_dir: dir, cwd: workspace)

      store.save(session_paths: ["/tmp/one.jsonl", "/tmp/two.jsonl"], active_index: 1)

      assert_equal ["/tmp/one.jsonl", "/tmp/two.jsonl"], store.load["session_paths"]
      assert_equal 1, store.load["active_index"]
      assert_equal 0o600, File.stat(store.path).mode & 0o777
    end
  end

  def test_loads_legacy_session_layout_as_tab_descriptors
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      store = Kward::TabStore.new(config_dir: dir, cwd: workspace)
      FileUtils.mkdir_p(File.dirname(store.path))
      File.write(store.path, JSON.dump({ "session_paths" => ["/tmp/one.jsonl"], "labels" => ["Main"], "active_index" => 0 }))

      assert_equal [{ "kind" => "session", "session_path" => "/tmp/one.jsonl", "label" => "Main" }], store.load["tabs"]
    end
  end

  def test_load_discards_duplicate_session_tab_descriptors
    Dir.mktmpdir do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      store = Kward::TabStore.new(config_dir: dir, cwd: workspace)
      session_path = File.join(dir, "session.jsonl")

      FileUtils.mkdir_p(File.dirname(store.path))
      File.write(store.path, JSON.dump({
        "tabs" => [
          { "kind" => "session", "session_path" => session_path, "label" => "Main" },
          { "kind" => "session", "session_path" => session_path, "label" => "Main" },
          { "kind" => "plugin", "plugin_tab_type" => "example.chat", "label" => "Example" }
        ],
        "active_index" => 2
      }))

      state = store.load
      assert_equal [session_path, nil], state["tabs"].map { |tab| tab["session_path"] }
      assert_equal ["Main", "Example"], state["labels"]
      assert_equal 1, state["active_index"]
    end
  end

  def test_save_and_load_plugin_tab_descriptor
    Dir.mktmpdir do |dir|
      store = Kward::TabStore.new(config_dir: dir, cwd: dir)
      descriptor = { "kind" => "plugin", "plugin_tab_type" => "example.chat", "label" => "Example" }

      store.save(tabs: [descriptor], active_index: 0)

      assert_equal [descriptor], store.load["tabs"]
    end
  end

  def test_save_and_load_worktree_tab_descriptor
    Dir.mktmpdir do |dir|
      store = Kward::TabStore.new(config_dir: dir, cwd: dir)
      descriptor = {
        "kind" => "session",
        "session_path" => File.join(dir, "session.jsonl"),
        "label" => "Feature",
        "worktree" => {
          "repository_root" => "/repo",
          "origin_root" => "/repo",
          "path" => "/worktrees/feature",
          "branch" => "kward/feature",
          "base_revision" => "abc123",
          "active" => true,
          "owned" => true
        }
      }

      store.save(tabs: [descriptor], active_index: 0)

      assert_equal [descriptor], store.load["tabs"]
    end
  end

  def test_load_returns_empty_state_for_missing_file
    Dir.mktmpdir do |dir|
      store = Kward::TabStore.new(config_dir: dir, cwd: dir)

      assert_equal({ "tabs" => [], "session_paths" => [], "labels" => [], "active_index" => 0 }, store.load)
    end
  end
end
