require_relative "base"
require_relative "../config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for reading configured skill instructions.
    class ReadSkill < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(skills: nil)
        name_property = { type: "string", description: "Skill name." }
        skill_names = Array(skills).map(&:name).compact.sort
        name_property[:enum] = skill_names unless skill_names.empty?

        super(
          "read_skill",
          "Read configured skill instructions/files.",
          properties: {
            name: name_property,
            path: { type: "string", description: "Path inside skill; default SKILL.md." }
          },
          required: ["name"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, conversation, cancellation: nil)
        name = argument(args, :name, "")
        path = argument(args, :path)
        workspace_root = conversation.respond_to?(:workspace_root) ? conversation.workspace_root : Dir.pwd

        ConfigFiles.read_skill_file(name, path, workspace_root: workspace_root)
      end
    end
  end
end
