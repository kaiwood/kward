require_relative "base"

module Kward
  module Tools
    # Proposes edits against the cursor or selected spans of one editor snapshot.
    class EditEditorBuffer < Base
      def initialize(editor_prompt_session:)
        @session = editor_prompt_session
        super(
          "edit_editor_buffer",
          "Propose targeted in-memory edits in one call. With a selection, target selection:1, selection:2, etc. Otherwise target cursor to insert or current_line to replace its text without consuming the line ending.",
          properties: {
            edits: {
              type: "array",
              items: {
                type: "object", additionalProperties: false, required: %w[target content],
                properties: { target: { type: "string" }, content: { type: "string", description: "Replacement text, or an empty string to delete the target." } }
              }
            }
          },
          required: ["edits"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        @session.edit(argument(args, :edits))
        "Editor draft updated. The file has not been saved."
      rescue EditorPromptSession::InvalidEdit => e
        "Editor edit rejected: #{e.message}"
      end
    end
  end
end
