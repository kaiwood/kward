require_relative "base"
require_relative "../workspace"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for bounded shell commands in the workspace or active shell.
    class RunShellCommand < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace: nil, shell_prompt_session: nil)
        raise ArgumentError, "RunShellCommand requires a workspace or shell session" unless workspace || shell_prompt_session
        raise ArgumentError, "RunShellCommand accepts only one execution target" if workspace && shell_prompt_session

        @workspace = workspace
        @shell_prompt_session = shell_prompt_session
        description = shell_prompt_session ?
          "Run a bounded noninteractive command in the active embedded shell session." :
          "Run a shell command from the workspace root."
        timeout_description = shell_prompt_session ?
          "Timeout seconds; defaults to the embedded shell setting." :
          "Timeout seconds; default 30."
        super(
          "run_shell_command",
          description,
          properties: {
            command: { type: "string", description: "Command to run." },
            timeout_seconds: { type: "integer", description: timeout_description }
          },
          required: ["command"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        command = argument(args, :command, "")
        timeout_seconds = argument(
          args,
          :timeout_seconds,
          @shell_prompt_session ? @shell_prompt_session.timeout_seconds : Workspace::DEFAULT_COMMAND_TIMEOUT_SECONDS
        )

        if @shell_prompt_session
          @shell_prompt_session.run(command, timeout_seconds: timeout_seconds, cancellation: cancellation)
        else
          @workspace.run_shell_command(command, timeout_seconds: timeout_seconds, cancellation: cancellation)
        end
      end
    end
  end
end
