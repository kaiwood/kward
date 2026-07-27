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
        else
          pending = coordinator.pending(candidates)
          unless pending.empty?
            decision = prompt_for_project_skill_trust(pending)
            coordinator.record!(pending, decision)
          end

          @interactive_project_skill_paths = coordinator.allowed_paths(candidates)
        end
        @prompt.update_slash_commands(slash_command_entries) if @prompt.respond_to?(:update_slash_commands)
      end

      def prompt_for_project_skill_trust(candidates)
        paths = candidates.map { |candidate| "  #{relative_workspace_path(candidate.path)}" }
        message = (["Project skills found in #{current_workspace_root}:", *paths, "", "These files contain instructions that may influence the model."]).join("\n")
        loop do
          choice = @prompt.select(message, ["Allow", "Deny", "Review"], title: "Trust project skills")
          case choice.to_s.downcase
          when "review"
            review_project_skills(candidates)
          when "allow"
            return "allow"
          else
            return "deny"
          end
        end
      end

      def review_project_skills(candidates)
        candidates.each do |candidate|
          content = read_project_skill_for_review(candidate.path)
          resources = project_skill_resources(candidate.path)
          details = [
            "Project skill: #{relative_workspace_path(candidate.path)}",
            resources.empty? ? nil : "Referenced resources:\n#{resources.map { |path| "  #{path}" }.join("\n")}",
            "",
            content
          ].compact.join("\n")
          @prompt.say("\n#{ANSI.strip(details)}\n")
        end
      end

      def read_project_skill_for_review(path)
        return "Unable to review: file is too large." if File.size(path) > ConfigFiles::MAX_SKILL_FILE_BYTES

        ANSI.strip(File.read(path, ConfigFiles::MAX_SKILL_FILE_BYTES + 1))
      rescue StandardError => e
        "Unable to review: #{e.message}"
      end

      def project_skill_resources(path)
        folder = File.dirname(path)
        roots = %w[scripts references assets].map { |name| File.join(folder, name) }.select { |root| Dir.exist?(root) }
        roots.flat_map { |root| Dir.glob(File.join(root, "**", "*")).select { |entry| File.file?(entry) } }.sort.first(200).map do |resource|
          Pathname.new(resource).relative_path_from(Pathname.new(folder)).to_s
        end
      rescue StandardError
        []
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
