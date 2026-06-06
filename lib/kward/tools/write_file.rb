require_relative "base"

module Kward
  module Tools
    class WriteFile < Base
      def initialize(workspace:)
        @workspace = workspace
        super(
          "write_file",
          "Write content to a file inside the current workspace. Existing files must be read first.",
          properties: {
            path: { type: "string", description: "Workspace-relative file path." },
            content: { type: "string", description: "Complete file content to write." }
          },
          required: ["path", "content"]
        )
      end

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
