require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model-callable tool wrappers and their argument schemas.
  module Tools
    # Replaces the active editor's in-memory draft without saving to disk.
    class ReplaceEditorBuffer < Base
      def initialize(editor_prompt_session:)
        @editor_prompt_session = editor_prompt_session
        super(
          "replace_editor_buffer",
          "Replace the entire in-memory buffer only for an explicit whole-buffer request without an active selection. This does not save the file.",
          properties: {
            content: { type: "string", description: "Complete replacement contents for the editor buffer." }
          },
          required: ["content"]
        )
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        content = argument(args, :content)
        @editor_prompt_session.replace(content)
        lines = content.each_line.count
        "Editor buffer replaced: #{lines} lines, #{content.to_s.bytesize} bytes. The file has not been saved."
      rescue EditorPromptSession::InvalidEdit => e
        "Editor edit rejected: #{e.message}"
      end
    end
  end
end
