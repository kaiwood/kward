require_relative "command_runner"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Preserves existing LocalCommandRunner behavior when sandboxing is off.
    class PassthroughRunner < CommandRunner
      def command_argv(command, cwd:)
        [command.to_s]
      end
    end
  end
end
