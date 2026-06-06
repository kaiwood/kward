require_relative "base"

module Kward
  module Tools
    class EditFile < Base
      def initialize(workspace:)
        @workspace = workspace
        super(
          "edit_file",
          "Edit an existing file inside the current workspace using exact text replacement. Existing files must be read first. Each old_text must match exactly once and edits must not overlap.",
          properties: {
            path: { type: "string", description: "Workspace-relative file path." },
            edits: {
              type: "array",
              description: "One or more non-overlapping replacements matched against the original file content.",
              items: {
                type: "object",
                properties: {
                  old_text: { type: "string", description: "Exact text to replace. Must be unique in the original file." },
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
