require "pathname"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Immutable, user-configured restrictions for a command worker.
    class Policy
      MODES = %w[off read_only workspace_write].freeze
      NETWORK_MODES = %w[deny allow].freeze

      attr_reader :mode, :network, :workspace_root, :writable_roots

      def initialize(mode: "off", network: "deny", workspace_root:, writable_roots: [], protect_git_metadata: true)
        @mode = normalize_mode(mode)
        @network = normalize_network(network)
        @workspace_root = canonical_path(workspace_root)
        @writable_roots = normalize_writable_roots(writable_roots)
        @protect_git_metadata = protect_git_metadata != false
      end

      def enabled?
        mode != "off"
      end

      def read_only?
        mode == "read_only"
      end

      def workspace_write?
        mode == "workspace_write"
      end

      def protect_git_metadata?
        @protect_git_metadata
      end

      def child_network_allowed?
        network == "allow"
      end

      def command_writable_roots
        return [] unless workspace_write?

        ([workspace_root] + writable_roots).uniq
      end

      private

      def normalize_mode(value)
        mode = value.to_s
        return mode if MODES.include?(mode)

        raise ArgumentError, "sandbox mode must be one of: #{MODES.join(", ")}"
      end

      def normalize_network(value)
        network = value.to_s
        return network if NETWORK_MODES.include?(network)

        raise ArgumentError, "sandbox network must be one of: #{NETWORK_MODES.join(", ")}"
      end

      def normalize_writable_roots(roots)
        Array(roots).map { |root| canonical_path(root) }.uniq.reject { |root| root == workspace_root }
      end

      def canonical_path(path)
        Pathname.new(path.to_s).realpath.to_s
      rescue Errno::ENOENT
        raise ArgumentError, "sandbox path does not exist: #{path}"
      end
    end
  end
end
