require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Tool wrapper for opening a workspace file in the integrated editor.
    class OpenEditor < Base
      # Builds the tool schema and stores the execution dependencies.
      def initialize(workspace:, prompt:)
        @workspace = workspace
        @prompt = prompt
        super(
          "open_editor",
          "Open a workspace file in Kward's integrated editor for the user. Use this when the user explicitly asks to open or edit a file in the built-in editor. This does not itself modify or save the file; the user controls those actions in the editor.",
          properties: {
            path: { type: "string", description: "Workspace-relative path of the file to open." }
          },
          required: ["path"]
        )
      end

      # Opens the requested file and returns after the editor closes.
      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        return "Error: open_editor requires interactive editor support." unless @prompt.respond_to?(:edit_file)

        path = argument(args, :path, "").to_s
        return "Error: open_editor requires a file path." if path.empty?

        resolved_path = @workspace.resolved_path(path)
        return "Error: not a file: #{path}" unless File.file?(resolved_path)

        opened = @prompt.edit_file(resolved_path, base_dir: @workspace.root, allow_new: false)
        opened ? "Opened #{path} in the integrated editor." : "Error: could not open #{path} in the integrated editor."
      rescue SecurityError, StandardError => e
        "Error: could not open #{path}: #{e.message}"
      end
    end
  end
end
