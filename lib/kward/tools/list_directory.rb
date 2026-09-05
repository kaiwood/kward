require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for listing workspace directory entries.
    class ListDirectory < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace:, workspace_targets: nil)
        configure_workspace_targets(workspace, workspace_targets)
        super(
          "list_directory",
          "List workspace directory entries.",
          properties: targeted_properties(path: { type: "string", description: "Workspace-relative directory." }),
          required: ["path"]
        )
      end

      # Executes the tool and returns model-facing output text.
      def call(args, _conversation, cancellation: nil)
        workspace_for(args).list_directory(argument(args, :path, "."))
      end
    end
  end
end
