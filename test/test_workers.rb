require_relative "test_helper"
require_relative "../lib/kward/workers"
require_relative "../lib/kward/session_store"

class TestWorkers < KwardTestCase
  def test_scout_worker_runs_with_read_only_policy_and_records_report
    Dir.mktmpdir do |dir|
      client = FakeClient.new([{ "role" => "assistant", "content" => "# Scout Report\nDone." }])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir
      )

      worker = manager.start(role: "scout", prompt: "Explore tests")
      wait_until(timeout: 1) { manager.find(worker.id).status == "ready" }

      assert_equal "scout", worker.role
      assert_equal "ready", worker.status
      assert_equal "# Scout Report\nDone.", worker.report
      refute_empty worker.event_history
    end
  end

  def test_worker_manager_attaches_worker_to_session
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      client = FakeClient.new([{ "role" => "assistant", "content" => "done" }])
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: workspace,
        session_store: session_store,
        provider: "openai",
        model: "gpt-test"
      )

      worker = manager.start(role: "scout", prompt: "Explore tests")
      wait_until(timeout: 1) { worker.status == "ready" && worker.session }

      assert worker.session
      assert File.file?(worker.session.path)
      assert_equal worker.session.path, worker.to_h.fetch("session_path")
      _session, conversation = session_store.load(worker.session.path, workspace: Kward::Workspace.new(root: workspace), provider: "openai", model: "gpt-test", reasoning_effort: nil)
      assert_equal "done", Kward::MessageAccess.content(conversation.messages.last)
    end
  end

  def test_tool_policy_limits_scout_tools
    names = Kward::Workers::ToolPolicy.allowed_tool_names("scout")

    assert_includes names, "read_file"
    refute_includes names, "write_file"
    refute_includes names, "edit_file"
    refute_includes names, "run_shell_command"
  end

  def test_worker_manager_reports_status_changes
    Dir.mktmpdir do |dir|
      statuses = []
      client = FakeClient.new([{ "role" => "assistant", "content" => "done" }])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir,
        on_status_change: ->(worker) { statuses << worker.status }
      )

      worker = manager.start(role: "scout", prompt: "Explore")
      wait_until(timeout: 1) { worker.status == "ready" }

      assert_includes statuses, "running"
      assert_includes statuses, "ready"
    end
  end
end
