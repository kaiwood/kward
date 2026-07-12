require_relative "test_helper"
require_relative "../lib/kward/prompt_interface/approval_prompt"

class TestApprovalPrompt < KwardTestCase
  def test_allows_only_an_explicit_allow_once_answer
    prompt = approval_prompt(answer: "Allow once")

    assert prompt.ask_tool_approval(tool_name: "run_shell_command", args: { command: "bundle exec rake" })
    assert_includes prompt.questions.first.first[:question], "Command: bundle exec rake"
  end

  def test_denies_cancelled_or_negative_answers
    refute approval_prompt(answer: "Deny").ask_tool_approval(tool_name: "write_file", args: { path: "lib/kward.rb" })
    refute approval_prompt(answer: nil).ask_tool_approval(tool_name: "write_file", args: { path: "lib/kward.rb" })
  end

  private

  def approval_prompt(answer:)
    Object.new.tap do |prompt|
      prompt.extend(Kward::PromptInterface::ApprovalPrompt)
      prompt.define_singleton_method(:questions) { @questions ||= [] }
      prompt.define_singleton_method(:ask_user_question) do |questions|
        self.questions << questions
        answer.nil? ? nil : [{ answer: answer }]
      end
    end
  end
end
