require_relative "command_runner"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Raised when a requested sandbox cannot be enforced on this host.
    class UnavailableError < StandardError
    end

    # Fails closed rather than running a requested sandbox policy unrestricted.
    class UnavailableRunner < CommandRunner
      def command_argv(command, cwd:)
        []
      end

      def run(command, cwd:, timeout_seconds:, max_output_bytes:, cancellation: nil, &block)
        raise UnavailableError, "Sandbox #{policy.mode} is unavailable: #{capabilities.reason}"
      end
    end
  end
end
