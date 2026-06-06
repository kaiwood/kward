require_relative "base"

module Kward
  module Tools
    class ReadFile < Base
      def initialize(workspace:)
        @workspace = workspace
        super(
          "read_file",
          "Read a text file inside the current workspace. Output is truncated to 2000 lines or 50KB, whichever is hit first. Use offset/limit to continue through large files.",
          properties: {
            path: { type: "string", description: "Workspace-relative file path." },
            offset: { type: "integer", description: "Optional 1-indexed line number to start reading from." },
            limit: { type: "integer", description: "Optional maximum number of lines to return." }
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
