require_relative "trust_store"

# Namespace for Agent Skills discovery and trust management.
module Kward
  module Skills
    # Resolves which discovered project skills need a user decision.
    class TrustCoordinator
      def initialize(workspace_root:, trust_store:)
        @workspace_root = workspace_root
        @trust_store = trust_store
      end

      def decision(candidate)
        @trust_store.decision(
          workspace_root: @workspace_root,
          skill_path: candidate.path,
          digest: candidate.digest
        )
      end

      def pending(candidates)
        candidates.reject { |candidate| decision(candidate) }
      end

      def allowed_paths(candidates)
        candidates.filter_map { |candidate| candidate.path if decision(candidate) == "allow" }
      end

      def remove_workspace!
        @trust_store.remove_workspace!(workspace_root: @workspace_root)
      end

      def record!(candidates, decision)
        candidates.each do |candidate|
          @trust_store.set_decision!(
            workspace_root: @workspace_root,
            skill_path: candidate.path,
            digest: candidate.digest,
            decision: decision
          )
        end
      end
    end
  end
end
