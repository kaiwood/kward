require_relative "base"

module Kward
  module Tools
    class ReadFile < Base
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
