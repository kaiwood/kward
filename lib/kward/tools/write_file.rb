require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for guarded full-file writes.
    class WriteFile < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace:)
        @workspace = workspace
        super(
          "write_file",
          "Write a workspace file. Existing files must be read first.",
          properties: {
            path: { type: "string", description: "Workspace-relative path." },
            content: { type: "string", description: "Complete file content." }
          },
          required: ["path", "content"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, conversation, cancellation: nil)
        path = argument(args, :path, "")
        content = argument(args, :content, "")

        result = @workspace.write_file(path, content, read_paths: conversation.read_paths)
        conversation.refresh_system_message! if agents_file_changed?(@workspace, path, result)
        result
      end
    end
  end
end
