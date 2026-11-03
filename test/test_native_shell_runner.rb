require_relative "test_helper"
require "open3"

class TestNativeShellRunner < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def run_kwsh(*args, input: "")
    Open3.capture3({ "SHELL" => "/must-not-be-launched" }, RbConfig.ruby, EXECUTABLE, *args, stdin_data: input)
  end

  def test_command_mode_uses_name_arguments_and_native_extensions
    output, error, status = run_kwsh("-c", 'values=(one "two words"); printf "%s:%s:%s:%s" "$0" "$1" "${values[1]}" "$((2**3))"', "program", "argument")
    assert status.success?, error
    assert_equal "program:argument:two words:8", output
    assert_empty error
  end

  def test_stdin_does_not_buffer_input_owned_by_read
    output, error, status = run_kwsh("-s", input: "read value\npayload\nprintf '%s' \"$value\"\n")
    assert status.success?, error
    assert_equal "payload", output
    assert_empty error
  end

  def test_file_mode_and_syntax_check
    Dir.mktmpdir("native-script") do |dir|
      file = File.join(dir, "example.kwsh")
      File.write(file, 'printf "%s" "$1"; exit 7')
      output, error, status = run_kwsh(file, "value")
      assert_equal 7, status.exitstatus
      assert_equal "value", output
      assert_empty error
      output, error, status = run_kwsh("-n", file)
      assert status.success?, error
      assert_empty output
      File.write(file, "if")
      _, error, status = run_kwsh("-n", file)
      assert_equal 2, status.exitstatus
      refute_empty error
    end
  end

  def test_invalid_invocations_fail_without_delegating
    _, error, status = run_kwsh("-c")
    assert_equal 2, status.exitstatus
    assert_includes error, "requires a command"
    _, error, status = run_kwsh("-o", "unknown", "-c", "printf bad")
    assert_equal 2, status.exitstatus
    assert_includes error, "unsupported option"
  end
end
