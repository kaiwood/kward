# Namespace for CLI orchestration helpers.
module Kward
  class CLI
    # Handles explicit project skill trust management commands.
    module ProjectSkillsCommands
      def handle_project_skills_cli_command(arguments)
        argument = Array(arguments).join(" ").strip.downcase
        _workspace_root, candidates, coordinator = project_skill_trust_coordinator
        if candidates.empty? && argument != "untrust"
          project_skills_cli_output("No project skills found in the current workspace.")
          return
        end

        case argument
        when "", "status"
          lines = candidates.empty? ? ["No project skills found in the current workspace."] : candidates.map { |candidate| "#{relative_workspace_path(candidate.path)}: #{coordinator.decision(candidate) || "needs review"}" }
          project_skills_cli_output(lines.join("\n"))
        when "trust"
          coordinator.record!(candidates, "allow")
          project_skills_cli_output("Project skills trusted for the current skill snapshots.")
        when "untrust"
          coordinator.remove_workspace!
          project_skills_cli_output("Project skill trust removed for this workspace.")
        when "review"
          review_project_skills(candidates)
        else
          raise ArgumentError, "Usage: kward skills [status|trust|untrust|review]"
        end
      end

      def handle_project_skills_command(argument)
        case argument.to_s.strip.downcase
        when "", "status"
          show_project_skills_status
        when "trust"
          trust_current_project_skills
        when "untrust"
          untrust_current_project_skills
        else
          runtime_output("Usage: /skills [status|trust|untrust]")
        end
      end

      private

      def project_skills_cli_output(message)
        @prompt.say("#{colored("Project skills", :green, :bold)}\n\n#{message}")
      end

      def project_skill_trust_coordinator
        workspace_root = current_workspace_root
        candidates = ConfigFiles.project_skill_candidates(workspace_root: workspace_root)
        store = Skills::TrustStore.new(config_dir: ConfigFiles.config_dir)
        [workspace_root, candidates, Skills::TrustCoordinator.new(workspace_root: workspace_root, trust_store: store)]
      end

      def show_project_skills_status
        _workspace_root, candidates, coordinator = project_skill_trust_coordinator
        if candidates.empty?
          runtime_output("No project skills found in the current workspace.")
          return
        end

        lines = candidates.map do |candidate|
          status = coordinator.decision(candidate) || "needs review"
          "#{relative_workspace_path(candidate.path)}: #{status}"
        end
        runtime_output(lines.join("\n"))
      end

      def trust_current_project_skills
        _workspace_root, candidates, coordinator = project_skill_trust_coordinator
        if candidates.empty?
          runtime_output("No project skills found in the current workspace.")
          return
        end

        coordinator.record!(candidates, "allow")
        @interactive_project_skill_paths = coordinator.allowed_paths(candidates)
        runtime_output("Project skills trusted for the current skill snapshots. Use /new to rebuild the agent.")
      end

      def untrust_current_project_skills
        _workspace_root, _candidates, coordinator = project_skill_trust_coordinator
        coordinator.remove_workspace!
        @interactive_project_skill_paths = []
        runtime_output("Project skill trust removed for this workspace. Use /new to rebuild the agent.")
      end
    end
  end
end
