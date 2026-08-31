require_relative "base"
require_relative "../shell/prompt_session"

# Namespace for the Kward agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Prepares a command in the active embedded shell without executing it.
    class PrepareShellCommand < Base
      def initialize(shell_prompt_session:)
        @shell_prompt_session = shell_prompt_session
        super(
          "prepare_shell_command",
          "Place a command in the active shell prompt without executing it. The user must press Enter to run it.",
          properties: {
            command: { type: "string", description: "Complete shell command to place in the prompt." }
          },
          required: ["command"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        @shell_prompt_session.prepare(argument(args, :command, ""))
      end
    end
  end
end
