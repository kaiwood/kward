require_relative "base"

module Kward
  module Tools
    class ListDirectory < Base
      def initialize(workspace:)
        @workspace = workspace
        super(
          "list_directory",
          "List workspace directory entries.",
          properties: { path: { type: "string", description: "Workspace-relative directory." } },
          required: ["path"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        @workspace.list_directory(argument(args, :path, "."))
      end
    end
  end
end
