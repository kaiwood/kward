require_relative "test_helper"
require_relative "../lib/kward/message_access"

class TestMessageAccess < KwardTestCase
  def test_reads_symbol_and_string_message_fields
    message = {
      "role" => "assistant",
      content: "hello",
      "name" => "read_file",
      tool_call_id: "call_1",
      "tool_calls" => [{ "id" => "call_1" }]
    }

    assert_equal "assistant", Kward::MessageAccess.role(message)
    assert_equal "hello", Kward::MessageAccess.content(message)
    assert_equal "read_file", Kward::MessageAccess.name(message)
    assert_equal "call_1", Kward::MessageAccess.tool_call_id(message)
    assert_equal [{ "id" => "call_1" }], Kward::MessageAccess.tool_calls(message)
  end

  def test_tool_calls_falls_back_to_empty_array
    assert_equal [], Kward::MessageAccess.tool_calls({ role: "assistant", tool_calls: nil })
    assert_equal [], Kward::MessageAccess.tool_calls(nil)
  end
end
