require_relative "../config_files"
require_relative "../sandbox"
require_relative "workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Builds workspaces with the same user-configured command sandbox in every frontend.
  module WorkspaceFactory
    module_function

    def build(root:, guardrails: true, config: ConfigFiles.read_config, strict: false)
      policy = ConfigFiles.sandbox_policy(root, config)
      policy = strict_policy(root, policy) if strict
      runner = Sandbox::RunnerFactory.build(policy)
      if strict && !runner.capabilities.filesystem_enforced?
        reason = runner.capabilities.reason || "filesystem enforcement is unavailable"
        raise Sandbox::UnavailableError, "Strict workspace sandbox is unavailable: #{reason}"
      end

      Workspace.new(root:, guardrails: strict ? true : guardrails, command_runner: runner)
    end

    def strict_policy(root, configured_policy)
      Sandbox::Policy.new(
        mode: "workspace_write",
        network: configured_policy.network,
        workspace_root: root,
        writable_roots: [],
        protect_git_metadata: configured_policy.protect_git_metadata?
      )
    end
    private_class_method :strict_policy
  end
end
