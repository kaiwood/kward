require_relative "test_helper"
require_relative "../lib/kward/workers"
require_relative "../lib/kward/session_store"

class TestWorkers < KwardTestCase
  def test_request_worker_runs_with_read_only_policy_and_records_report
    Dir.mktmpdir do |dir|
      client = FakeClient.new([{ "role" => "assistant", "content" => "# Request Review\nDone." }])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir
      )

      worker = manager.start(role: "request", prompt: "Explore tests")
      wait_until(timeout: 1) { manager.find(worker.id).status == "ready" }

      assert_equal "request", worker.role
      assert_equal "ready", worker.status
      assert_equal "# Request Review\nDone.", worker.report
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

      worker = manager.start(role: "request", prompt: "Explore tests")
      wait_until(timeout: 1) { worker.status == "ready" && worker.session }

      assert worker.session
      assert File.file?(worker.session.path)
      assert_equal worker.session.path, worker.to_h.fetch("session_path")
      _session, conversation = session_store.load(worker.session.path, workspace: Kward::Workspace.new(root: workspace), provider: "openai", model: "gpt-test", reasoning_effort: nil)
      assert_equal "done", Kward::MessageAccess.content(conversation.messages.last)
    end
  end

  def test_live_view_drains_new_worker_events
    worker = Kward::Workers::Worker.new(id: "abc123", title: "Watch", role: "request", status: "running", prompt: "Watch")
    seen = []
    view = Kward::Workers::LiveView.new(worker: worker, agent: Object.new, renderer: ->(event, _agent) { seen << event }, poll_interval: 0.01).start

    worker.event_history << :event_one
    worker.update_status("ready")

    wait_until(timeout: 1) { seen.include?(:event_one) }
    view.stop
  end

  def test_worker_manager_archives_runtime_worker
    Dir.mktmpdir do |dir|
      client = FakeClient.new([{ "role" => "assistant", "content" => "done" }])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir
      )

      worker = manager.start(role: "request", prompt: "Explore tests")
      wait_until(timeout: 1) { worker.status == "ready" }
      manager.archive(worker.id)

      assert_equal "archived", worker.status
      assert_empty manager.list
    end
  end

  def test_worker_store_persists_worker_metadata
    Dir.mktmpdir do |dir|
      store = Kward::Workers::Store.new(path: File.join(dir, "workers.json"))
      worker = Kward::Workers::Worker.new(id: "abc123", title: "Implement", role: "implementation", workspace_root: dir, status: "queued", prompt: "Do it")

      store.upsert(worker)
      restored = Kward::Workers::Store.new(path: store.path).find("abc123")

      assert_equal "implementation", restored.fetch("role")
      assert_equal "Implement", restored.fetch("title")
    end
  end

  def test_write_capable_worker_waits_for_write_lock
    Dir.mktmpdir do |dir|
      write_lock = Kward::Workers::WriteLock.new
      assert write_lock.acquire("implementation")
      client = FakeClient.new([{ "role" => "assistant", "content" => "done" }])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir,
        write_lock: write_lock
      )

      worker = manager.start(role: "implementation", prompt: "Change files")
      sleep 0.05
      assert_equal "queued", worker.status

      write_lock.release("implementation")
      wait_until(timeout: 1) { worker.status == "ready" }

      assert_equal "done", worker.report
    end
  end

  def test_tool_policy_limits_request_tools
    names = Kward::Workers::ToolPolicy.allowed_tool_names("request")

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

      worker = manager.start(role: "request", prompt: "Explore")
      wait_until(timeout: 1) { worker.status == "ready" }

      assert_includes statuses, "running"
      assert_includes statuses, "ready"
    end
  end
end
