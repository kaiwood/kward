require_relative "test_helper"
require_relative "../lib/kward/prompt_interface/approval_prompt"

class TestApprovalPrompt < KwardTestCase
  def test_allows_once_and_shows_all_arguments
    prompt = approval_prompt(answer: "Allow once")

    assert prompt.ask_tool_approval(tool_name: "read_skill", args: { name: "documentation-writer", path: "references/style.md" })
    assert_includes prompt.questions.first.first[:question], '"name": "documentation-writer"'
    assert_includes prompt.questions.first.first[:question], '"path": "references/style.md"'
  end

  def test_shows_web_search_queries_and_filters
    prompt = approval_prompt(answer: "Allow once")

    assert prompt.ask_tool_approval(
      tool_name: "web_search",
      args: { queries: ["Ruby sandboxing"], domain_filter: ["ruby-lang.org"], recency_filter: "month" }
    )

    question = prompt.questions.first.first[:question]
    assert_includes question, '"queries": ['
    assert_includes question, '"domain_filter": ['
    assert_includes question, '"recency_filter": "month"'
  end

  def test_returns_custom_text_as_a_denial_message
    prompt = approval_prompt(answer: "Use the supplied token instead.", custom: true)

    assert_equal(
      { denied_message: "Use the supplied token instead." },
      prompt.ask_tool_approval(tool_name: "read_file", args: { path: ".env" })
    )
  end

  def test_can_allow_a_tool_for_the_session
    prompt = approval_prompt(answer: "Allow this tool for this session")

    assert_equal :allow_for_session, prompt.ask_tool_approval(tool_name: "run_shell_command", args: { command: "bundle exec rake" })
  end

  def test_denies_cancelled_or_negative_answers
    refute approval_prompt(answer: "Deny").ask_tool_approval(tool_name: "write_file", args: { path: "lib/kward.rb" })
    refute approval_prompt(answer: nil).ask_tool_approval(tool_name: "write_file", args: { path: "lib/kward.rb" })
  end

  private

  def approval_prompt(answer:, custom: false)
    Object.new.tap do |prompt|
      prompt.extend(Kward::PromptInterface::ApprovalPrompt)
      prompt.define_singleton_method(:questions) { @questions ||= [] }
      prompt.define_singleton_method(:ask_user_question) do |questions|
        self.questions << questions
        answer.nil? ? nil : [{ answer: answer, custom: custom }]
      end
    end
  end
end
