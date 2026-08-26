# Namespace for the Kward CLI agent runtime.
module Kward
  # Builds the model-facing request for an in-memory editor prompt.
  module EditorPrompt
    module_function

    def system_message
      {
        role: "system",
        content: <<~PROMPT.strip
          You are Kward's in-memory editor assistant.

          Act only on the user's explicit request about the active editor buffer. Do not volunteer changes, explanations, or unrelated work. For an actionable edit request, call replace_editor_buffer with the complete replacement buffer. For a request that is only a question or needs clarification, answer briefly without changing the buffer. Never write files to disk and never claim that the buffer was saved.
        PROMPT
      }
    end

    def input(instruction, context)
      document = context[:display_path].to_s
      language = context[:language].to_s
      language = "text" if language.empty?
      content = context[:content].to_s

      <<~PROMPT
        You are operating inside an interactive editor.

        The user requested:
        #{instruction}

        Active document: #{document.empty? ? "(untitled)" : document}
        Language: #{language}
        Cursor: line #{context.dig(:cursor, 0).to_i + 1}, column #{context.dig(:cursor, 1).to_i + 1}
        Selected text: #{context[:selection].to_s.empty? ? "(none)" : "present; full-buffer replacement is required"}

        Current buffer:
        <editor_buffer>
        #{content}
        </editor_buffer>

        Satisfy the user's request by calling replace_editor_buffer with the complete desired buffer contents.
        The operation changes only the in-memory editor buffer. Do not write files to disk.
        If the request is ambiguous, explain the ambiguity instead of changing the buffer.
      PROMPT
    end
  end
end
