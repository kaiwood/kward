require_relative "test_helper"
require_relative "../lib/kward/tool_output_compactor"

class TestToolOutputCompactor < KwardTestCase
  def test_returns_original_when_compaction_would_not_save_tokens
    content = Array.new(1_500) { |index| "ERROR: repeated failure #{index}" }.join("\n")
    compactor = Kward::ToolOutputCompactor.new

    result = compactor.compact("run_shell_command", content, artifact_id: "toolout_test")

    assert_equal content, result
  end

  def test_short_error_output_stays_verbatim
    content = "Exit status: 1\n\nSTDERR:\nERROR: exact short failure"
    compactor = Kward::ToolOutputCompactor.new

    result = compactor.compact("run_shell_command", content, artifact_id: "toolout_test")

    assert_equal content, result
  end
end
