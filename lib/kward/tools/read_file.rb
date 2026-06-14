require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for bounded workspace file reads.
    class ReadFile < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace:)
        @workspace = workspace
        super(
          "read_file",
          "Read a workspace text file. Output is capped; use offset/limit to continue.",
          properties: {
            path: { type: "string", description: "Workspace-relative path." },
            offset: { type: "integer", description: "1-indexed start line." },
            limit: { type: "integer", description: "Maximum lines to return." }
          },
          required: ["path"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, conversation, cancellation: nil)
        path = argument(args, :path, "")
        offset = argument(args, :offset)
        limit = argument(args, :limit)
        content = @workspace.read_file(path, offset: offset, limit: limit)
        conversation.mark_read(@workspace.resolved_path(path)) unless content.start_with?("Error:")
        content
      end
    end
  end
end
