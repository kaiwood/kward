require_relative "test_helper"
require_relative "../lib/kward/workspace/factory"

class TestWorkspaceFactory < KwardTestCase
  def test_strict_worktree_workspace_keeps_file_guardrails_enabled
    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", workspace_root: dir)
      capabilities = Kward::Sandbox::RunnerFactory.build(policy).capabilities
      skip "filesystem sandbox unavailable" unless capabilities.filesystem_enforced?

      workspace = Kward::WorkspaceFactory.build(
        root: dir,
        guardrails: false,
        config: { "sandbox" => { "mode" => "off" } },
        strict: true
      )

      result = workspace.write_file("../outside.txt", "unsafe\n", read_paths: [])

      assert_match(/path outside workspace/, result)
    end
  end

  def test_builds_a_workspace_with_existing_behavior_when_sandbox_is_off
    Dir.mktmpdir do |dir|
      workspace = Kward::WorkspaceFactory.build(root: dir, config: { "sandbox" => { "mode" => "off" } })

      output = workspace.run_shell_command("printf sandbox-off")

      assert_includes output, "Exit status: 0"
      assert_includes output, "sandbox-off"
    end
  end
end
