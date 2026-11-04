require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

# POSIX.1-2024 requirements, not snapshots of a particular host shell.
class TestNativeShellPosix < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def run_script(source, **options)
    Open3.capture3({ "LC_ALL" => "C" }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  def test_fatal_errors_exit_noninteractive_shells_even_in_conditions
    # 2.8.1: these errors do not depend on errexit or AND-OR position.
    ["readonly x=1; x=2", "export 1bad=value", ". /__kwsh_missing__/file",
     ": </__kwsh_missing__/file", "set -o invalid", "printf '%s' \"${missing:?required}\"",
     "printf '%s' \"$((1 / 0))\"", "readonly x=; printf '%s' \"${x:=value}\""].each do |command|
      output, error, status = run_script("trap 'printf exit:%s \"$?\"' EXIT; #{command}; printf bad")
      assert_equal 2, status.exitstatus, command
      assert_equal "exit:2", output, command
      refute_empty error
    end
    output, error, status = run_script("readonly x=1; x=2 || printf bad; printf bad")
    assert_equal 2, status.exitstatus
    assert_empty output
    refute_empty error
  end

  def test_ordinary_and_command_wrapped_builtin_errors_do_not_exit
    ["cd /__kwsh_missing__", "true </__kwsh_missing__/file",
     "{ :; } </__kwsh_missing__/file", "f() { :; }; f </__kwsh_missing__/file",
     "command export 1bad=value", "command : </__kwsh_missing__/file"].each do |command|
      output, error, status = run_script("#{command}; printf survived")
      assert_equal 0, status.exitstatus, command
      assert_equal "survived", output, command
      refute_empty error
    end
  end

  def test_fatal_errors_in_subshells_do_not_exit_the_parent
    output, error, status = run_script("(readonly x=1; x=2; printf bad); printf 'parent:%s' \"$?\"")
    assert_equal 0, status.exitstatus
    assert_equal "parent:2", output
    refute_empty error
  end

  def test_interactive_errors_abort_the_submission_but_leave_the_session_usable
    runtime = Kward::NativeShell::Runtime.new(interactive: true)
    output = StringIO.new
    error = StringIO.new
    assert_equal 2, runtime.run("readonly x=1; x=2; exit 9", output: output, error: error)
    refute runtime.exited
    assert_empty output.string
    assert_equal 0, runtime.run(":", output: output, error: error)
  ensure
    runtime&.close
  end

  def test_errexit_is_inherited_by_command_substitutions
    output, error, status = run_script("set -e; trap 'printf exit:%s \"$?\"' EXIT; value=$(false; printf bad); printf bad")
    assert_equal 1, status.exitstatus
    assert_equal "exit:1", output
    assert_empty error
    output, error, status = run_script("set -e; value=$(false; printf allowed) || :; printf '%s' \"$value\"")
    assert_equal 0, status.exitstatus
    assert_equal "allowed", output
    assert_empty error
  end

  def test_errexit_exceptions_for_conditions_negation_and_compound_commands
    ["false && true", "! true", "if false; then :; fi", "while false; do :; done",
     "{ false && true; }", "if true; then false && true; fi",
     "f() { false; printf function; }; if f; then :; fi", "false | true"].each do |command|
      output, error, status = run_script("set -e; #{command}; printf survived")
      assert_equal 0, status.exitstatus, "#{command}: #{error}"
      assert output.end_with?("survived"), command
      assert_empty error
    end
    ["true | false", "true && false", "(false && true)"].each do |command|
      output, error, status = run_script("set -e; #{command}; printf bad")
      assert_equal 1, status.exitstatus, command
      assert_empty output
      assert_empty error
    end
  end
end
