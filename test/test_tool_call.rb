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

  def test_value_preserves_falsey_values
    assert_equal false, Kward::ToolCall.value({ active: false }, :active)
    assert_equal 0, Kward::ToolCall.value({ "count" => 0 }, :count)
  end

  def test_normalizes_names_and_camelizes_nested_arguments
    assert_equal "edit", Kward::ToolCall.normalized_name("edit_file")
    assert_equal "code_search", Kward::ToolCall.normalized_name("code_search")
    assert_equal({ timeoutSeconds: 7, nestedValue: [{ oldText: "old" }] }, Kward::ToolCall.camelize_args({ "timeout_seconds" => 7, "nested_value" => [{ "old_text" => "old" }] }))
  end

  def test_classifies_write_lock_and_file_change_tools
    assert Kward::ToolCall.write_lock_required?("edit_file")
    assert Kward::ToolCall.write_lock_required?("write_file")
    assert Kward::ToolCall.write_lock_required?("run_shell_command")
    assert Kward::ToolCall.write_lock_required?("bash")
    refute Kward::ToolCall.write_lock_required?("read_file")

    assert Kward::ToolCall.file_change_tool?("edit_file")
    assert Kward::ToolCall.file_change_tool?("write")
    refute Kward::ToolCall.file_change_tool?("run_shell_command")
    refute Kward::ToolCall.file_change_tool?("bash")
  end
end
