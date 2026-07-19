require_relative "config_files"
require_relative "sandbox"
require_relative "workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Builds workspaces with the same user-configured command sandbox in every frontend.
  module WorkspaceFactory
    module_function

    def build(root:, guardrails: true, config: ConfigFiles.read_config)
      policy = ConfigFiles.sandbox_policy(root, config)
      runner = Sandbox::RunnerFactory.build(policy)
      Workspace.new(root:, guardrails:, command_runner: runner)
    end
  end
end
