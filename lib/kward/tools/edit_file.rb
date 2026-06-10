require_relative "base"

module Kward
  module Tools
    class EditFile < Base
      def initialize(workspace:)
        @workspace = workspace
        super(
          "edit_file",
          "Edit a read workspace file by exact replacements. Each old_text must match once; edits must not overlap.",
          properties: {
            path: { type: "string", description: "Workspace-relative path." },
            edits: {
              type: "array",
              description: "Non-overlapping replacements against original content.",
              items: {
                type: "object",
                properties: {
                  old_text: { type: "string", description: "Unique exact text to replace." },
                  new_text: { type: "string", description: "Replacement text." }
                },
                required: ["old_text", "new_text"],
                additionalProperties: false
              }
            }
          },
          required: ["path", "edits"]
        )
      end

      def call(args, conversation, cancellation: nil)
        path = argument(args, :path, "")
        edits = argument(args, :edits, [])

        result = @workspace.edit_file(path, edits, read_paths: conversation.read_paths)
        conversation.refresh_system_message! if agents_file_changed?(@workspace, path, result)
        result
      end
    end
  end
end
