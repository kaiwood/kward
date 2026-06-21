require_relative "test_helper"
require_relative "../lib/kward/workers"

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
