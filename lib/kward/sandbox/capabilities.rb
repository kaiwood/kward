# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Describes the enforcement a platform runner can provide.
    class Capabilities
      attr_reader :backend, :reason

      def initialize(available:, filesystem_enforced:, child_network_enforced:, backend:, reason: nil)
        @available = available == true
        @filesystem_enforced = filesystem_enforced == true
        @child_network_enforced = child_network_enforced == true
        @backend = backend.to_s
        @reason = reason&.to_s
      end

      def available?
        @available
      end

      def filesystem_enforced?
        @filesystem_enforced
      end

      def child_network_enforced?
        @child_network_enforced
      end

      def to_h
        {
          available: available?,
          filesystemEnforced: filesystem_enforced?,
          childNetworkEnforced: child_network_enforced?,
          backend: backend,
          reason: reason
        }.compact
      end
    end
  end
end
