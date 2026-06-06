require_relative "base"

module Kward
  module Tools
    class ListDirectory < Base
      def initialize(workspace:)
        @workspace = workspace
        super(
          "list_directory",
          "List files and directories inside the current workspace.",
          properties: { path: { type: "string", description: "Workspace-relative directory path." } },
          required: ["path"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        @workspace.list_directory(argument(args, :path, "."))
      end
    end
  end
end
