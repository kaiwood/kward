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

  class FakeGitGuard
    Result = Struct.new(:success, :stdout, :stderr, :commit, keyword_init: true) do
      def success?
        success
      end

      def output
        [stdout, stderr].compact.reject(&:empty?).join("\n")
      end
    end

    attr_reader :commits

    def initialize(repository: true, clean_values: [true])
      @repository = repository
      @clean_values = clean_values
      @commits = []
    end

    def repository?
      @repository
    end

    def clean?
      @clean_values.length > 1 ? @clean_values.shift : @clean_values.first
    end

    def commit_all(message)
      @commits << message
      Result.new(success: true, stdout: "", stderr: "", commit: "abc1234")
    end
  end

  def test_worker_queue_runner_runs_next_session_job_and_commits_changes
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      session = session_store.create(provider: "openai", model: "gpt-test")
      conversation = Kward::Conversation.new(workspace_root: workspace)
      session.attach(conversation)
      queue_store = Kward::Workers::QueueStore.new(path: File.join(dir, "worker_queue.json"))
      job = queue_store.enqueue(id: "job1", title: "Implement tab", session_path: session.path, workspace_root: workspace)
      git_guard = FakeGitGuard.new(clean_values: [true, false])
      client = FakeClient.new([{ "role" => "assistant", "content" => "implemented" }])
      runner = Kward::Workers::QueueRunner.new(
        queue_store: queue_store,
        session_store: session_store,
        client_factory: -> { client },
        workspace_root: workspace,
        provider: "openai",
        model: "gpt-test",
        git_guard: git_guard
      )

      runner.run_next

      record = queue_store.find(job.id)
      assert_equal "ready_for_review", record.fetch("status")
      assert_equal "abc1234", record.fetch("commit_sha")
      assert_equal ["Kward worker job1: Implement tab"], git_guard.commits
    end
  end

  def test_worker_queue_runner_blocks_when_workspace_is_dirty
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "config")
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      session_store = Kward::SessionStore.new(config_dir: config_dir, cwd: workspace)
      session = session_store.create(provider: "openai", model: "gpt-test")
      session.attach(Kward::Conversation.new(workspace_root: workspace))
      queue_store = Kward::Workers::QueueStore.new(path: File.join(dir, "worker_queue.json"))
      job = queue_store.enqueue(id: "job1", title: "Implement tab", session_path: session.path, workspace_root: workspace)
      runner = Kward::Workers::QueueRunner.new(
        queue_store: queue_store,
        session_store: session_store,
        client_factory: -> { FakeClient.new([{ "role" => "assistant", "content" => "implemented" }]) },
        workspace_root: workspace,
        git_guard: FakeGitGuard.new(clean_values: [false])
      )

      runner.run_next

      record = queue_store.find(job.id)
      assert_equal "blocked", record.fetch("status")
      assert_includes record.fetch("error"), "Workspace is dirty"
    end
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

  def test_worker_manager_continue_replaces_request_with_implementation
    Dir.mktmpdir do |dir|
      store = Kward::Workers::Store.new(path: File.join(dir, "workers.json"))
      client = FakeClient.new([
        { "role" => "assistant", "content" => "review" },
        { "role" => "assistant", "content" => "implemented" }
      ])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir,
        worker_store: store,
        git_guard: FakeGitGuard.new(repository: false)
      )

      request = manager.start(role: "request", prompt: "Explore tests", id: "abc123")
      wait_until(timeout: 1) { request.status == "ready" }
      implementation = manager.continue("abc123", role: "implementation", prompt: "Implement tests")
      wait_until(timeout: 1) { implementation.status == "ready" }

      assert_equal ["abc123"], manager.list.map(&:id)
      assert_equal ["implementation"], manager.list.map(&:role)
      assert_equal "implementation", store.find("abc123").fetch("role")
      assert_equal "implemented", store.find("abc123").fetch("report")
    end
  end

  def test_write_capable_worker_commits_dirty_workspace_after_run
    Dir.mktmpdir do |dir|
      git_guard = FakeGitGuard.new(clean_values: [true, false])
      client = FakeClient.new([{ "role" => "assistant", "content" => "changed files" }])
      manager = Kward::Workers::Manager.new(
        client_factory: -> { client },
        workspace_root: dir,
        git_guard: git_guard
      )

      worker = manager.start(role: "implementation", prompt: "Change files", id: "abc123")
      wait_until(timeout: 1) { worker.status == "ready" }

      assert_equal ["Kward worker abc123: Change files"], git_guard.commits
      assert_includes worker.report, "Committed workspace changes: abc1234"
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

  def test_worker_queue_store_enqueues_session_backed_jobs
    Dir.mktmpdir do |dir|
      store = Kward::Workers::QueueStore.new(path: File.join(dir, "worker_queue.json"))

      first = store.enqueue(id: "job1", title: "Implement one", session_path: File.join(dir, "one.jsonl"), workspace_root: dir)
      second = store.enqueue(id: "job2", title: "Implement two", session_path: File.join(dir, "two.jsonl"), workspace_root: dir)

      assert_equal "queued", first.status
      assert_equal ["job1", "job2"], store.list.map { |job| job.fetch("id") }
      assert_equal [1, 2], store.list.map { |job| job.fetch("position") }
      assert_equal "job1", store.next_queued.fetch("id")
      assert_equal "Implement two", store.find(second.id).fetch("title")
    end
  end

  def test_worker_queue_store_updates_status_and_hides_archived_jobs
    Dir.mktmpdir do |dir|
      store = Kward::Workers::QueueStore.new(path: File.join(dir, "worker_queue.json"))
      store.enqueue(id: "job1", title: "Implement one", session_path: File.join(dir, "one.jsonl"), workspace_root: dir)

      ready = store.update_status("job1", "ready_for_review", commit_sha: "abc123")
      assert_equal "ready_for_review", ready.fetch("status")
      assert_equal "abc123", ready.fetch("commit_sha")
      refute_nil ready.fetch("finished_at")

      store.archive("job1")
      assert_empty store.list
      assert_equal ["job1"], store.list(include_archived: true).map { |job| job.fetch("id") }
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
