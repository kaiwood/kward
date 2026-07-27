require "pathname"
require_relative "../skills/trust_coordinator"
require_relative "../skills/trust_store"

# Namespace for CLI orchestration helpers.
module Kward
  class CLI
    # Coordinates interactive trust decisions for project-provided Agent Skills.
    module ProjectSkills
      private

      def prepare_interactive_project_skills
        return unless prompt_interface?

        workspace_root = current_workspace_root
        candidates = ConfigFiles.project_skill_candidates(workspace_root: workspace_root)
        trust_store = Skills::TrustStore.new(config_dir: ConfigFiles.config_dir)
        coordinator = Skills::TrustCoordinator.new(workspace_root: workspace_root, trust_store: trust_store)

        if ConfigFiles.project_skills_trusted?
          @interactive_project_skill_paths = candidates.map(&:path)
          return
        end

        pending = coordinator.pending(candidates)
        unless pending.empty?
          decision = prompt_for_project_skill_trust(pending)
          coordinator.record!(pending, decision)
        end

        @interactive_project_skill_paths = coordinator.allowed_paths(candidates)
      end

      def prompt_for_project_skill_trust(candidates)
        paths = candidates.map { |candidate| "  #{relative_workspace_path(candidate.path)}" }
        message = (["Project skills found in #{current_workspace_root}:", *paths, "", "These files contain instructions that may influence the model."]).join("\n")
        choice = @prompt.select(message, ["Allow", "Deny"], title: "Trust project skills")
        choice.to_s.downcase == "allow" ? "allow" : "deny"
      end

      def project_skill_paths_for(workspace_root)
        return unless @interactive_project_skill_paths
        return unless canonical_path(workspace_root) == canonical_path(current_workspace_root)

        @interactive_project_skill_paths
      end

      def canonical_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def relative_workspace_path(path)
        Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(current_workspace_root))).to_s
      end
    end
  end
end
