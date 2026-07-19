require_relative "capabilities"
require_relative "passthrough_runner"
require_relative "unavailable_runner"
require_relative "macos_seatbelt_runner"
require_relative "linux_bubblewrap_runner"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Selects the command runner that can enforce a policy on the current host.
    module RunnerFactory
      module_function

      def build(policy, platform: RUBY_PLATFORM)
        return PassthroughRunner.new(policy:, capabilities: off_capabilities) unless policy.enabled?

        runner_class = runner_class_for(platform)
        return UnavailableRunner.new(policy:, capabilities: unsupported_capabilities(platform)) unless runner_class

        capabilities = runner_class.capabilities(platform:)
        return UnavailableRunner.new(policy:, capabilities:) unless capabilities.available?

        runner_class.new(policy:, capabilities:)
      end

      def off_capabilities
        Capabilities.new(
          available: true,
          filesystem_enforced: false,
          child_network_enforced: false,
          backend: "off"
        )
      end

      def unsupported_capabilities(platform)
        Capabilities.new(
          available: false,
          filesystem_enforced: false,
          child_network_enforced: false,
          backend: "unsupported",
          reason: "Sandboxing is unsupported on #{platform}"
        )
      end

      def runner_class_for(platform)
        value = platform.to_s
        return MacOSSeatbeltRunner if value.include?("darwin")
        return LinuxBubblewrapRunner if value.include?("linux")

        nil
      end
      private_class_method :runner_class_for
    end
  end
end
