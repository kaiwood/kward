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
        question = (["The agent wants to #{summary}."] + details + [reason.to_s].reject(&:empty?)).join("\n")
        answers = ask_user_question([
          {
            header: "Approval required · #{tool_approval_title(tool_name)}",
            question: question,
            options: [
              { label: "Allow once", description: "Run this tool call." },
              { label: "Deny", description: "Do not run this tool call." }
            ]
          }
        ])
        answers&.first&.fetch(:answer, nil) == "Allow once"
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
        args = args.to_h
        case tool_name.to_s
        when "run_shell_command"
          ["Command: #{args[:command] || args["command"]}"]
        when "write_file", "edit_file"
          ["Path: #{args[:path] || args["path"]}"]
        when "fetch_content", "fetch_raw"
          ["URL: #{args[:url] || args["url"]}"]
        when "web_search"
          ["Queries: #{Array(args[:queries] || args["queries"]).join(", ")}"]
        else
          []
        end
      end
    end
  end
end
