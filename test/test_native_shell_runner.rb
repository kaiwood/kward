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

  def test_exit_traps_run_once_on_normal_exit_and_errexit
    output, error, status = run_kwsh("-c", %q{trap 'printf "exit:%s" "$?"' EXIT; false})
    assert_equal 1, status.exitstatus
    assert_equal "exit:1", output
    assert_empty error
    output, error, status = run_kwsh("-e", "-c", %q{trap 'printf "exit:%s" "$?"; exit 9' 0; false; printf bad})
    assert_equal 9, status.exitstatus
    assert_equal "exit:1", output
    assert_empty error
  end

  def test_subshell_exit_traps_are_local
    output, error, status = run_kwsh("-c", %q{trap 'printf parent' EXIT; (trap 'printf child' EXIT; exit 3); printf ':'})
    assert status.success?, error
    assert_equal "child:parent", output
    assert_empty error
  end

  def test_exec_replaces_the_script_process_and_skips_exit_traps
    code = 'print Process.pid; exit 7'
    source = "printf '%s:' \"$$\"; trap 'printf bad' EXIT; exec #{Shellwords.escape(RbConfig.ruby)} -e #{Shellwords.escape(code)}; printf bad"
    output, error, status = run_kwsh("-c", source)
    assert_equal 7, status.exitstatus
    before, after = output.split(":")
    assert_match(/\A[0-9]+\z/, before)
    assert_equal before, after
    assert_empty error
  end

  def test_exec_can_clear_environment_and_pass_argv_zero_without_a_shell
    output, error, status = run_kwsh("-c", "export KW_TEST=value; exec -c #{Shellwords.escape(RbConfig.ruby)} -e 'print ENV.key?(%q[KW_TEST])'")
    assert status.success?, error
    assert_equal "false", output
    assert_empty error
  end

  def test_file_execution_is_incremental_and_read_uses_stdin
    Dir.mktmpdir("native-script") do |dir|
      file = File.join(dir, "example.kwsh")
      File.write(file, "alias say='printf %s'\nread value\nsay \"$value\"\nprintf before\nif\n")
      output, error, status = run_kwsh(file, input: "payload\n")
      assert_equal 2, status.exitstatus
      assert_equal "payloadbefore", output
      assert_includes error, "expected"
    end
  end

  def test_wait_is_interruptible_by_a_trapped_signal
    source = %q{trap 'printf signal:' USR1; { sleep 0.1; kill -USR1 $$; sleep 0.1; } & pid=$!; wait "$pid"; printf '%s:' "$?"; wait "$pid"; printf '%s' "$?"}
    output, error, status = run_kwsh("-c", source)
    assert status.success?, error
    assert_equal "signal:#{128 + Signal.list.fetch('USR1')}:0", output
    assert_empty error
  end

  def test_exec_prefix_assignments_are_exported
    output, error, status = run_kwsh("-c", "KW_TEST=prefix exec #{Shellwords.escape(RbConfig.ruby)} -e 'print ENV.fetch(%q[KW_TEST])'")
    assert status.success?, error
    assert_equal "prefix", output
    assert_empty error
  end

  def test_exec_interprets_executable_text_with_the_same_pid_and_fresh_traps
    Dir.mktmpdir("native-exec") do |dir|
      file = File.join(dir, "text with spaces")
      File.write(file, %q{printf '%s:%s:' "$$" "$1"; trap 'printf child' EXIT; exit 7})
      File.chmod(0o700, file)
      source = "printf '%s:' \"$$\"; trap 'printf parent' EXIT; exec #{Shellwords.escape(file)} 'two words'; printf bad"
      output, error, status = run_kwsh("-c", source)
      assert_equal 7, status.exitstatus
      before, after, argument, trap = output.split(":")
      assert_match(/\A[0-9]+\z/, before)
      assert_equal before, after
      assert_equal "two words", argument
      assert_equal "child", trap
      assert_empty error
    end
  end

  def test_exec_executable_text_can_clear_environment_and_keep_input
    Dir.mktmpdir("native-exec") do |dir|
      file = File.join(dir, "text")
      File.write(file, %q{read value; printf '%s:%s' "$value" "${KW_TEST-unset}"})
      File.chmod(0o700, file)
      output, error, status = run_kwsh("-c", "export KW_TEST=secret; exec -c #{Shellwords.escape(file)}", input: "payload\n")
      assert status.success?, error
      assert_equal "payload:unset", output
      assert_empty error
    end
  end

  def test_failed_exec_runs_exit_trap_without_interpreting_nonexecutable_text
    Dir.mktmpdir("native-exec") do |dir|
      file = File.join(dir, "text")
      File.write(file, "printf must-not-run")
      File.chmod(0o600, file)
      output, error, status = run_kwsh("-c", "trap 'printf \"exit:%s\" \"$?\"' EXIT; exec #{Shellwords.escape(file)}")
      assert_equal 126, status.exitstatus
      assert_equal "exit:126", output
      assert_includes error, "Permission denied"
    end
  end

  def test_unicode_source_and_locale_changes_work_when_started_in_c_locale
    with_env("LC_ALL" => "C") do
      output, error, status = run_kwsh("-c", 'value=é; printf "%s:" "${#value}"; LC_ALL=C.UTF-8; printf "%s" "${#value}"')
      assert status.success?, error
      assert_equal "2:1", output
      assert_empty error
      output, error, status = run_kwsh("-c", "printf '%s' '\xff'".b)
      assert status.success?, error
      assert_equal "\xff".b, output.b
      assert_empty error
    end
  end

  def test_repeated_exec_redirections_release_replaced_descriptors
    Dir.mktmpdir("native-descriptors") do |dir|
      source = "for ((i=0; i<200; i++)); do exec 3>#{Shellwords.escape(File.join(dir, 'output'))}; done; exec 3>&-; printf done"
      launcher = "require 'kward/shell/script_runner'; Process.setrlimit(:NOFILE, 64); exit Kward::NativeShell::ScriptRunner.run(['-c', ARGV.fetch(0)])"
      output, error, status = Open3.capture3(RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", launcher, source)
      assert status.success?, error
      assert_equal "done", output
      assert_empty error
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
