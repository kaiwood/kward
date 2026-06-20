require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Returns a compact symbol outline for a workspace source file.
    class SummarizeFileStructure < Base
      # Builds the tool schema and stores the execution dependency.
      def initialize(workspace:)
        @workspace = workspace
        super(
          "summarize_file_structure",
          "Return a compact outline of classes, modules, methods, and functions in a workspace source file.",
          properties: {
            path: { type: "string", description: "Workspace-relative source file path." }
          },
          required: ["path"]
        )
      end

      # Executes the structure summary tool.
      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        @workspace.summarize_file_structure(argument(args, :path, ""))
      end
    end
  end
end
