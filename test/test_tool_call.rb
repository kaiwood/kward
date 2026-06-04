require_relative "test_helper"

class TestToolCall < KwardTestCase
  def test_reads_name_id_and_arguments_from_string_or_symbol_keys
    string_call = tool_call("edit_file", { path: "a.txt", edits: [{ old_text: "old", new_text: "new" }] })
    symbol_call = {
      id: "call_symbol",
      function: {
        name: "run_shell_command",
        arguments: { command: "echo hi" }
      }
    }

    assert_equal "call_edit_file", Kward::ToolCall.id(string_call)
    assert_equal "edit_file", Kward::ToolCall.name(string_call)
    assert_equal "a.txt", Kward::ToolCall.arguments(string_call)["path"]
    assert_equal "call_symbol", Kward::ToolCall.id(symbol_call)
    assert_equal "run_shell_command", Kward::ToolCall.name(symbol_call)
    assert_equal({ command: "echo hi" }, Kward::ToolCall.arguments(symbol_call))
  end

  def test_invalid_or_empty_arguments_parse_to_empty_hash
    assert_equal({}, Kward::ToolCall.parse_arguments(nil))
    assert_equal({}, Kward::ToolCall.parse_arguments(""))
    assert_equal({}, Kward::ToolCall.parse_arguments("not-json"))
  end

  def test_normalizes_names_and_camelizes_nested_arguments
    assert_equal "edit", Kward::ToolCall.normalized_name("edit_file")
    assert_equal({ timeoutSeconds: 7, nestedValue: [{ oldText: "old" }] }, Kward::ToolCall.camelize_args({ "timeout_seconds" => 7, "nested_value" => [{ "old_text" => "old" }] }))
  end
end
