require_relative "../test_helper"
require_relative "../../lib/kward/sandbox"

class TestSandboxRunnerFactory < KwardTestCase
  def test_off_policy_uses_passthrough_runner
    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(workspace_root: dir)

      runner = Kward::Sandbox::RunnerFactory.build(policy, platform: "unknown")

      assert_instance_of Kward::Sandbox::PassthroughRunner, runner
      assert_equal "off", runner.capabilities.backend
    end
  end

  def test_requested_unsupported_policy_fails_closed
    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "read_only", workspace_root: dir)

      runner = Kward::Sandbox::RunnerFactory.build(policy, platform: "unknown")

      assert_instance_of Kward::Sandbox::UnavailableRunner, runner
      error = assert_raises(Kward::Sandbox::UnavailableError) do
        runner.run("echo should-not-run", cwd: dir, timeout_seconds: 1, max_output_bytes: 100)
      end
      assert_includes error.message, "Sandbox read_only is unavailable"
    end
  end
end
