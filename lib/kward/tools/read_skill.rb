require_relative "base"
require_relative "../config_files"

module Kward
  module Tools
    class ReadSkill < Base
      def initialize
        super(
          "read_skill",
          "Read configured skill instructions or related files from the Kward config skills directory.",
          properties: {
            name: { type: "string", description: "Configured skill name." },
            path: { type: "string", description: "Optional path relative to the skill folder. Defaults to SKILL.md." }
          },
          required: ["name"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        name = argument(args, :name, "")
        path = argument(args, :path)

        ConfigFiles.read_skill_file(name, path)
      end
    end
  end
end
