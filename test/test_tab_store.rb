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

  def test_load_returns_empty_state_for_missing_file
    Dir.mktmpdir do |dir|
      store = Kward::TabStore.new(config_dir: dir, cwd: dir)

      assert_equal({ "session_paths" => [], "active_index" => 0 }, store.load)
    end
  end
end
