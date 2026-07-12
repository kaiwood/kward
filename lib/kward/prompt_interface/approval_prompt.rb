require "json"

# Namespace for the Kward CLI agent runtime.
module Kward
  class PromptInterface
    # Tool-approval overlay built on the structured question modal.
    module ApprovalPrompt
      # Asks the captain to approve a model-requested tool call. Cancellation is
      # intentionally a denial so a closed or interrupted overlay never permits
      # a side effect.
      def ask_tool_approval(tool_name:, args:, reason: nil)
        summary, details = tool_approval_details(tool_name, args)
        question = (["The agent wants to #{summary}."] + Array(details) + [reason.to_s].reject(&:empty?)).join("\n")
        answers = ask_user_question([
          {
            header: "Approval required · #{tool_approval_title(tool_name)}",
            question: question,
            options: [
              { label: "Allow once", description: "Run this tool call." },
              { label: "Allow this tool for this session", description: "Run this call and future calls to #{tool_name}." },
              { label: "Deny", description: "Do not run this tool call." }
            ]
          }
        ])
        case answers&.first&.fetch(:answer, nil)
        when "Allow once" then true
        when "Allow this tool for this session" then :allow_for_session
        else false
        end
      end

      private

      def tool_approval_title(tool_name)
        case tool_name.to_s
        when "run_shell_command" then "Shell command"
        when "write_file" then "Write file"
        when "edit_file" then "Edit file"
        when "fetch_content", "fetch_raw" then "Network request"
        when "web_search" then "Web search"
        else tool_name.to_s.tr("_", " ").capitalize
        end
      end

      def tool_approval_details(tool_name, args)
        action = case tool_name.to_s
                 when "run_shell_command" then "run this shell command"
                 when "write_file" then "write this file"
                 when "edit_file" then "edit this file"
                 when "read_file", "read_skill" then "read these resources"
                 when "fetch_content", "fetch_raw" then "make this network request"
                 when "web_search" then "search the web"
                 else "use #{tool_name}"
                 end
        [action, ["Arguments:\n#{JSON.pretty_generate(args.to_h)}"]]
      end
    end
  end
end
