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
          "Read a workspace text file. Output is capped; use offset/limit or mode to control context budget.",
          properties: {
            path: { type: "string", description: "Workspace-relative path." },
            limit: { type: "integer", description: "Maximum lines to return." },
            max_bytes: { type: "integer", description: "Optional byte budget for this read, capped by Kward's workspace read limit." },
            mode: { type: "string", enum: %w[preview outline range full], description: "Context mode. preview returns a short slice, outline returns source declarations, range reads offset/limit, full reads until Kward's cap." },
            offset: { type: "integer", description: "1-indexed start line." }
          },
          required: ["path"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, conversation, cancellation: nil)
        path = argument(args, :path, "")
        offset = argument(args, :offset)
        limit = argument(args, :limit)
        mode = argument(args, :mode)
        max_bytes = argument(args, :max_bytes)
        content = @workspace.read_file(path, offset: offset, limit: limit, mode: mode, max_bytes: max_bytes)
        conversation.mark_read(@workspace.resolved_path(path)) unless content.start_with?("Error:")
        content
      end
    end
  end
end
