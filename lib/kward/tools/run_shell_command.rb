require_relative "base"
require_relative "../workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for bounded shell commands in the workspace.
    class RunShellCommand < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace:)
        @workspace = workspace
        super(
          "run_shell_command",
          "Run a shell command from the workspace root.",
          properties: {
            command: { type: "string", description: "Command to run." },
            timeout_seconds: { type: "integer", description: "Timeout seconds; default 30." }
          },
          required: ["command"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        command = argument(args, :command, "")
        timeout_seconds = argument(args, :timeout_seconds, Workspace::DEFAULT_COMMAND_TIMEOUT_SECONDS)

        @workspace.run_shell_command(command, timeout_seconds: timeout_seconds, cancellation: cancellation)
      end
    end
  end
end
