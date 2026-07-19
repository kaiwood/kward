require_relative "test_helper"
require_relative "../lib/kward/workspace_factory"

class TestWorkspaceFactory < KwardTestCase
  def test_builds_a_workspace_with_existing_behavior_when_sandbox_is_off
    Dir.mktmpdir do |dir|
      workspace = Kward::WorkspaceFactory.build(root: dir, config: { "sandbox" => { "mode" => "off" } })

      output = workspace.run_shell_command("printf sandbox-off")

      assert_includes output, "Exit status: 0"
      assert_includes output, "sandbox-off"
    end
  end
end
