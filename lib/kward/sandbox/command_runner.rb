require_relative "../pty/local_command_runner"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Base command runner. Platform runners provide an argv that is then executed
    # through LocalCommandRunner, preserving Kward's timeout and cancellation behavior.
    class CommandRunner
      def initialize(policy:, capabilities:)
        @policy = policy
        @capabilities = capabilities
      end

      attr_reader :policy, :capabilities

      def run(command, cwd:, timeout_seconds:, max_output_bytes:, cancellation: nil, &block)
        LocalCommandRunner.new(
          timeout_seconds: timeout_seconds,
          max_output_bytes: max_output_bytes
        ).run(*command_argv(command, cwd: cwd), cwd: cwd, cancellation: cancellation, &block)
      end

      def command_argv(command, cwd:)
        raise NotImplementedError, "#{self.class} must implement #command_argv"
      end
    end
  end
end
