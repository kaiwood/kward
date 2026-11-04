require_relative "test_helper"
require "open3"
require_relative "../lib/kward/shell/native_runtime"

# POSIX.1-2024 requirements, not snapshots of a particular host shell.
class TestNativeShellPosix < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def run_script(source, **options)
    Open3.capture3({ "LC_ALL" => "C" }, RbConfig.ruby, EXECUTABLE, "-c", source, **options)
  end

  # Clause references make additions reviewable without treating Bash as the
  # oracle. Cases use only specified behavior (not optional pipeline state).
  CONFORMANCE_CASES = {
    "2.2 quoting and line continuation" => ["value=hel\\\nlo; printf '%s' \"$value\"", "hello"],
    "2.5.2 quoted positional parameters" => [%q{set -- 'a b' '' c; printf '<%s>' pre"$@"post}, "<prea b><><cpost>"],
    "2.6.2 lazy parameter operands" => [%q{x=set; printf '%s:%s' "${x:-${missing:?bad}}" "${absent+${missing:?bad}}"}, "set:"],
    "2.6.3 command substitution status" => [%q{x=$(exit 7); printf '%s' "$?"}, "7"],
    "2.6.5 splitting only expansion results" => [%q{IFS=:; x='a::b'; printf '<%s>' before:$x:after}, "<before:a><><b:after>"],
    "2.9.3 AND-OR precedence" => [%q{true || false && printf yes; false && true || printf ':yes'}, "yes:yes"],
    "2.9.5 function positional scope" => [%q{set -- parent; f() { printf '%s:' "$1"; return 7; }; f child; printf '%s:%s' "$?" "$1"}, "child:7:parent"],
    "2.15 temporary versus special assignments" => [%q{x=old; x=temporary true; printf '%s:' "$x"; x=persist :; printf '%s' "$x"}, "old:persist"],
    "2.15 command suppresses assignment persistence" => [%q{x=old; x=temporary command :; printf '%s' "$x"}, "old"],
    "getopts reset and argument ownership" => [%q{set -- -ab value tail; while getopts ab: option; do printf '%s:%s|' "$option" "${OPTARG-unset}"; done; printf '%s' "$OPTIND"}, "a:unset|b:value|3"],
    "wait collects explicit child status" => [%q{(exit 7) & child=$!; wait "$child"; printf '%s' "$?"}, "7"],
    "2.15 EXIT trap status" => [%q{trap 'printf "%s" "$?"' EXIT; exit 9}, "9", 9]
  }.freeze

  def test_posix_requirement_matrix
    CONFORMANCE_CASES.each do |requirement, (source, expected, exit_status)|
      output, error, status = run_script(source)
      assert_equal exit_status || 0, status.exitstatus, "#{requirement}: #{error}"
      assert_equal expected, output, requirement
      assert_empty error, requirement
    end
  end

  def test_redirection_words_are_not_split_or_globbed
    Dir.mktmpdir("posix-redirection") do |dir|
      output, error, status = run_script(<<~'SHELL', chdir: dir)
        file='two words'
        printf content >$file
        printf literal >'*.txt'
        cat <${file}
        cat <*.txt
      SHELL
      assert status.success?, error
      assert_equal "contentliteral", output
      assert_empty error
      assert File.file?(File.join(dir, "two words"))
      assert File.file?(File.join(dir, "*.txt"))
    end
  end

  def test_here_document_line_continuation_precedes_delimiter_recognition
    output, error, status = run_script(<<~'SHELL')
      cat <<EOF
      hel\
      lo
      EO\
      F
      printf done
    SHELL
    assert status.success?, error
    assert_equal "hello\ndone", output
    assert_empty error
    output, error, status = run_script(<<~'SHELL')
      cat <<'EOF'
      $HOME\
      literal
      EOF
    SHELL
    assert status.success?, error
    assert_equal "$HOME\\\nliteral\n", output
    assert_empty error
  end

  def test_failed_special_redirection_preserves_earlier_stderr_redirection
    Dir.mktmpdir("posix-errors") do |dir|
      output, error, status = run_script(": 2>errors <missing; printf bad", chdir: dir)
      assert_equal 2, status.exitstatus
      assert_empty output
      assert_empty error
      assert_includes File.read(File.join(dir, "errors")), "missing"
    end
  end

  def test_arithmetic_expands_shell_syntax_once_before_integer_evaluation
    output, error, status = run_script(<<~'SHELL')
      x=2
      printf '%s:%s:%s:%s' "$(( $(printf '%s' '2') + 1 ))" "$((1 + $((2 + 3))))" "$(( ${x:-4} + `printf 5` ))" "$((1$(printf 2)))"
    SHELL
    assert_equal 0, status.exitstatus, error
    assert_equal "3:6:7:12", output
    assert_empty error
    output, error, status = run_script(%q{x='$(printf injected)'; printf '%s' "$(( $x ))"; printf bad})
    assert_equal 2, status.exitstatus
    assert_empty output
    assert_includes error, "arithmetic"
  end

  def test_arithmetic_syntax_checks_do_not_execute_nested_substitutions
    Dir.mktmpdir("posix-arithmetic") do |dir|
      source = %q{printf '%s' "$(( $(printf 2 >sentinel) + $((3)) ))"}
      output, error, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "-n", "-c", source, chdir: dir)
      assert status.success?, error
      assert_empty output
      refute File.exist?(File.join(dir, "sentinel"))
      output, error, status = run_script("if false; then #{source}; fi", chdir: dir)
      assert status.success?, error
      refute File.exist?(File.join(dir, "sentinel"))
    end
  end

  def test_case_fallthrough_does_not_expand_the_skipped_patterns
    output, error, status = run_script(<<~'SHELL')
      case x in
        x) printf one ;&
        ${missing:?must-not-expand}) printf two ;&
        y) false ;;
        x) printf bad ;;
      esac
      printf ':%s' "$?"
    SHELL
    assert_equal 0, status.exitstatus, error
    assert_equal "onetwo:1", output
    assert_empty error
  end

  def test_invocation_resets_ifs_but_later_assignments_still_work
    output, error, status = Open3.capture3({ "IFS" => ":" }, RbConfig.ruby, EXECUTABLE, "-c",
      %q{x=a:b; set -- $x; printf '%s:' "$#"; IFS=:; set -- $x; printf '%s' "$#"})
    assert_equal 0, status.exitstatus, error
    assert_equal "1:2", output
    assert_empty error
  end

  def test_lineno_tracks_incremental_input_functions_and_nested_commands
    output, error, status = run_script(<<~'SHELL')
      printf '%s:' "$LINENO"
      f() {
        printf '%s:' "$LINENO"
      }
      f
      printf '%s:' "$LINENO"
      printf '%s:' "$(printf '%s' "$LINENO")"
      LINENO=42
      printf '%s' "$LINENO"
    SHELL
    assert_equal 0, status.exitstatus, error
    assert_equal "1:3:6:7:42", output
    assert_empty error
  end

  def test_command_reports_functions_before_ordinary_builtins
    output, error, status = run_script("pwd() { :; }; command -V pwd; command -v pwd")
    assert_equal 0, status.exitstatus, error
    assert_equal "pwd is function\npwd\n", output
    assert_empty error
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
