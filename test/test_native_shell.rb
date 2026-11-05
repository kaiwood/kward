require_relative "test_helper"
require "tempfile"
require_relative "../lib/kward/shell/native_runtime"

class TestNativeShell < KwardTestCase
  def setup
    super
    @directory = Dir.mktmpdir("native-kwsh")
    @runtime = Kward::NativeShell::Runtime.new(cwd: @directory, env: { "PATH" => ENV.fetch("PATH"), "HOME" => @directory })
  end

  def teardown
    @runtime.close
    FileUtils.remove_entry(@directory)
    super
  end

  def execute(source, runtime: @runtime)
    Tempfile.create("native-output") do |output|
      Tempfile.create("native-error") do |error|
        File.open(File::NULL) do |input|
          status = runtime.run(source, input: input, output: output, error: error)
          output.rewind
          error.rewind
          return [status, output.read, error.read]
        end
      end
    end
  end

  def assert_output(expected, source, status: 0)
    actual_status, output, error = execute(source)
    assert_equal status, actual_status, error
    assert_equal "", error
    assert_equal expected, output
  end

  def test_resumed_child_status_supersedes_a_stale_stop_report
    reader, writer = IO.pipe
    pid = Process.fork do
      writer.close
      Process.kill("STOP", Process.pid)
      reader.read(1)
      Process.kill("STOP", Process.pid)
      reader.read(1)
      exit!(7)
    end
    reader.close
    original_wait = Process.method(:wait2)
    # Reproduce continuation after wait obtains a stop, but before the native
    # supervisor handles it. The child stays alive so continuation is observable.
    Process.define_singleton_method(:wait2) do |child, flags|
      result = original_wait.call(child, flags)
      Process.kill("CONT", child) if result.last.stopped?
      result
    end
    status = Kward::NativeShell::NativeProcess.wait(pid)
    refute status.stopped?, "a resumed child must not be reported as stopped"
    refute status.exited?
    refute status.signaled?
    Process.define_singleton_method(:wait2, original_wait)

    writer.write("x")
    writer.flush
    status = Kward::NativeShell::NativeProcess.wait(pid)
    assert status.stopped?, "a subsequent genuine stop must still be reported"
    Process.kill("CONT", pid)
    writer.write("x")
    writer.flush
    exit_status = @runtime.send(:wait, pid)
    pid = nil
    assert_equal 7, exit_status
  ensure
    Process.define_singleton_method(:wait2, original_wait) if original_wait
    if pid
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        # The child may have exited while an assertion was failing.
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        # A terminal status may already have been collected.
      end
    end
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_background_lists_have_isolated_state_and_waitable_statuses
    assert_output("parent:7:1:127", <<~'SHELL')
      value=parent
      { value=child; exit 7; } & first=$!
      false && printf bad & second=${!}
      wait "$first"; printf '%s:%s:' "$value" "$?"
      wait "$second"; printf '%s:' "$?"
      wait "$first"; printf '%s' "$?"
    SHELL
  end

  def test_wait_all_returns_zero_and_subshells_have_no_parent_jobs
    assert_output("0:0:127", <<~'SHELL')
      false & pid=$!
      (wait; printf '%s:' "$?")
      wait; printf '%s:' "$?"
      wait "$pid"; printf '%s' "$?"
    SHELL
  end

  def test_background_stdin_is_null_unless_explicitly_redirected
    File.write(File.join(@directory, "input"), "value\n")
    assert_output("1:value", <<~'SHELL')
      read item & wait $!; printf '%s:' "$?"
      { read item <input; printf '%s' "$item"; } & wait
    SHELL
  end

  def test_background_pipeline_status_and_job_ids
    assert_output("0:1", 'false | true & wait %1; printf "%s:" "$?"; set -o pipefail; false | true & wait %+; printf "%s" "$?"')
  end

  def test_kill_and_wait_report_signal_status
    assert_output((128 + Signal.list.fetch("TERM")).to_s, 'sleep 30 & pid=$!; kill -TERM %1; wait "$pid"; printf "%s" "$?"')
  end

  def test_traps_run_native_source_preserve_status_and_restore_host_handlers
    before = Signal.trap("USR1", "IGNORE")
    assert_output("signal:0:after", %q{trap 'printf "signal:%s:" "$?"' USR1; kill -USR1 $$; printf after})
    assert_equal "IGNORE", Signal.trap("USR1", "IGNORE")
  ensure
    Signal.trap("USR1", before)
  end

  def test_traps_reset_and_list_without_executing_actions
    assert_output("", "trap 'printf bad' USR1; trap - USR1; trap")
    assert_output("", "trap '' USR1; kill -USR1 $$")
    assert_equal 2, execute("trap ':' KILL").first
  end

  def test_exec_descriptors_persist_and_duplicate_before_closing
    assert_output("visible:saved:", <<~'SHELL')
      exec 3>output
      printf saved >&3
      exec 4>&3 3>&-
      printf : >&4
      exec 4>&-
      printf visible:
      cat output
    SHELL
  end

  def test_aliases_expand_tokens_not_values_and_honor_trailing_blanks
    assert_output("yes:yes:yes", <<~'SHELL')
      alias say='printf %s'
      alias indirect='say '
      alias word=yes
      indirect word
      alias choose='if'
      choose true; then printf :yes; fi
      alias say='printf :yes'
      say
    SHELL
  end

  def test_aliases_do_not_expand_quoted_or_parameter_command_names
    assert_output("yes", <<~'SHELL')
      alias printf='false'
      "printf" '%s' yes
      name=printf
      $name ''
    SHELL
  end

  def test_alias_changes_wait_until_the_next_complete_input_unit
    assert_output("oldnew", <<~'SHELL')
      alias say='printf old'
      alias say='printf new'; say
      say
    SHELL
  end

  def test_recursive_aliases_stop_at_the_same_name
    assert_output("okay", <<~'SHELL')
      alias printf='printf %s'
      printf okay
    SHELL
  end

  def test_locale_controls_character_lengths_classes_and_collating_symbols
    assert_output("3:6:yes:yes:no", <<~'SHELL')
      LC_ALL=C.UTF-8
      value='é猫a'
      printf '%s:' "${#value}"
      LC_ALL=C
      printf '%s:' "${#value}"
      case a in [[.a.]]) printf yes:;; esac
      case a in [[=a=]]) printf yes:;; esac
      case é in [[:alpha:]]) printf bad;; *) printf no;; esac
    SHELL
  end

  def test_locale_is_scoped_and_invalid_names_fail_explicitly
    assert_output("2", 'LC_ALL=C; value=é; printf "%s" "${#value}"')
    assert_output("1", 'LC_ALL=C.UTF-8; value=é; printf "%s" "${#value}"')
    status, _, error = execute('LC_ALL=kwsh_nonexistent_locale; value=x; printf "%s" "${#value}"')
    assert_equal 2, status
    assert_includes error, "unavailable locale"
  end

  def test_recursive_globs_skip_hidden_files_and_symlink_cycles
    FileUtils.mkdir_p(File.join(@directory, "a", "b"))
    File.write(File.join(@directory, "a", "b", "data.txt"), "")
    File.write(File.join(@directory, "a", ".hidden.txt"), "")
    File.symlink(@directory, File.join(@directory, "a", "loop"))
    assert_output("<a/b/data.txt>", "shopt -s globstar; printf '<%s>' **/*.txt")
    assert_output("<a/><a/b/><a/loop/>", "shopt -s globstar; printf '<%s>' **/")
    assert_output("<a><a/b><a/b/data.txt><a/loop>", "shopt -s globstar; printf '<%s>' **")
    assert_output("<a/b/data.txt>", "printf '<%s>' a/[[.b.]]/*.txt")
  end

  def test_aliases_are_expanded_inside_substitutions
    assert_output("one:two", <<~'SHELL')
      alias say='printf %s'
      printf '%s:%s' "$(say one)" "`say two`"
    SHELL
  end

  def test_named_user_and_assignment_tildes_preserve_quoted_prefixes
    user = Etc.getpwuid
    assert_output("#{user.dir}:#{@directory}:#{user.dir}:~missing_kwsh_user", "printf '%s:' ~#{user.name}; paths=~:~#{user.name}; printf '%s:' \"$paths\"; printf '%s' ~missing_kwsh_user")
    assert_output("~root:~root", %q{printf '%s:' ~"root"; user=root; printf '%s' ~$user})
    assert_output("#{@directory}:#{@directory}/bin", 'export paths=~:~/bin; printf "%s" "$paths"')
  end

  def test_blank_lines_and_comments_preserve_status
    assert_output("1", "false\n# explanation\n\nprintf '%s' \"$?\"\n")
  end

  def test_exec_option_terminator_preserves_redirects
    assert_output("stored", 'exec -- 3>saved; printf stored >&3; exec 3>&-; cat saved')
  end

  def test_empty_alias_is_an_empty_input_line
    assert_output("yes", "alias empty=''\nempty\nprintf yes\n")
  end

  def test_locale_scope_restores_the_calling_threads_locale_even_on_error
    locale = Kward::NativeShell::Locale
    before = locale::USE.call(0).to_i
    locale.with("LC_ALL" => "C.UTF-8") do |active|
      assert_equal Encoding::UTF_8, active.encoding
      assert_raises(Kward::NativeShell::ExecutionError) { locale.with("LC_ALL" => "kwsh_missing_locale") { flunk } }
    end
    assert_equal before, locale::USE.call(0).to_i
  end

  def test_job_selectors_and_signal_name_translation
    assert_output("#{Signal.list.fetch('TERM')}:TERM", 'number=$(kill -l TERM); name=$(kill -l 143); printf "%s:%s" "$number" "$name"')
    assert_output("0", 'sleep 0.01 & wait %sleep; printf "%s" "$?"')
  end

  def test_locale_objects_are_released_using_platform_ownership_rules
    locale = Kward::NativeShell::Locale
    original = locale::FREE.method(:call)
    released = []
    locale::FREE.define_singleton_method(:call) { |handle| released << handle.to_i; original.call(handle) }
    locale.with("LC_ALL" => "C") { |active| assert_equal Encoding::BINARY, active.encoding }
    assert_equal locale::DARWIN ? 2 : 1, released.length
    assert_equal released.uniq, released
  ensure
    locale::FREE.singleton_class.send(:remove_method, :call)
  end

  def test_oversized_kill_pids_fail_without_ending_the_interpreter
    status, _, error = execute("kill #{'9' * 100}")
    assert_equal 2, status
    assert_includes error, "invalid pid"
    assert_output("alive", "printf alive")
  end

  def test_arithmetic_expansion_adds_the_requested_numbers
    assert_output("7\n", 'echo $((5 + 2))')
  end

  def test_arithmetic_precedence_grouping_unary_signs_and_integer_bases
    assert_output("11:21:-6:18", 'printf "%s:%s:%s:%s" "$((5 + 2 * 3))" "$(((5 + 2) * 3))" "$((-(5 + 2) + +1))" "$((010 + 0xA))"')
  end

  def test_arithmetic_division_truncates_toward_zero_and_remainder_follows_dividend
    assert_output("-2:-1:-2:1", 'printf "%s:%s:%s:%s" "$((-7 / 3))" "$((-7 % 3))" "$((7 / -3))" "$((7 % -3))"')
  end

  def test_arithmetic_variables_assignments_arguments_and_loop_updates
    assert_output("7:8:9:0:3", <<~'SHELL')
      value=5
      result=$((value + 2))
      printf '%s:%s:%s:%s' "$result" "$(( $value + 3 ))" "$(( ${value} + 4 ))" "$((unset_value))"
      set -- 2
      count=0
      while [ "$count" -lt "$1" ]; do count=$((count + 1)); done
      printf ':%s' "$((count + $1 - 1))"
    SHELL
  end

  def test_arithmetic_respects_quoting_and_word_concatenation
    assert_output("before7after:$((5 + 2)):$((5 + 2))", %q{printf '%s:%s:%s' before$((5 + 2))after '$((5 + 2))' "\$((5 + 2))"})
  end

  def test_invalid_arithmetic_is_rejected_before_any_side_effects
    ["5 +", "1=2", "1++", "2**", "1; touch sentinel", "values[0]", "1.5", "08", "1 <<", "1 <"].each do |expression|
      status, _, error = execute("printf touched >sentinel; echo $((#{expression}))")
      assert_equal 2, status, expression
      refute_empty error
      refute File.exist?(File.join(@directory, "sentinel")), expression
    end
  end

  def test_arithmetic_validation_does_not_evaluate_skipped_branches_or_read_future_variables
    assert_output("7", 'if false; then echo $((1 / 0)); fi; value=5; printf "%s" "$((value + 2))"')
  end

  def test_arithmetic_runtime_errors_do_not_launch_the_command
    ["echo $((1 / 0)) >sentinel", "echo $((1 % 0)) >sentinel", "value='$(touch sentinel)'; echo $((value))", "value=value; echo $((value))"].each do |source|
      status, _, error = execute(source)
      assert_equal 2, status, source
      assert_includes error, "arithmetic"
      refute File.exist?(File.join(@directory, "sentinel"))
    end
    assert_output("2", 'printf "%s" "$?"')
  end

  def test_arithmetic_accepts_horizontal_space_between_closing_parentheses
    assert_output("7\n", 'echo $((5 + 2) )')
    assert_output("7\n", "echo $((5 + 2) \t )")
    assert_output("value=21!", 'printf "%s" "value=$(((5 + 2) * 3) )!"')
    assert_output("7:9", 'value=$((5 + 2) ); printf "%s:%s" "$value" "$((value + 2) )"')
  end

  def test_spaced_arithmetic_closers_do_not_rewrite_literal_text
    assert_output('$((5 + 2) )|$((5 + 2) )', %q{printf '%s|%s' '$((5 + 2) )' "\$((5 + 2) )"})
  end

  def test_arithmetic_rejects_other_tokens_between_closers_before_side_effects
    ['echo $((5 + 2); touch sentinel)', 'echo $((5 + 2) x)', "echo $((5 + 2)\n)", 'echo $((5 + 2) ) )'].each do |source|
      status, _, error = execute("printf touched >sentinel; #{source}")
      assert_equal 2, status, source
      refute_empty error
      refute File.exist?(File.join(@directory, "sentinel")), source
    end
  end

  def test_incomplete_arithmetic_allows_continuation
    assert_raises(Kward::NativeShell::IncompleteInput) { Kward::NativeShell::Parser.parse('echo $((5 +') }
    assert_output("7\n", "echo $((5 +\n2))")
    assert_output("7\n", "echo $((5 +\n2) )")
  end

  def test_arithmetic_limits_nesting_expression_length_and_result_size
    expressions = ["(" * 101 + "1" + ")" * 101, "1+" * 2_048 + "1", "9" * 1_234]
    expressions.each do |expression|
      status, _, error = execute("echo $((#{expression}))")
      assert_equal 2, status
      assert_includes error, "exceeds"
    end
    value = "9" * 700
    status, _, error = execute("value=#{value}; echo $((value * value))")
    assert_equal 2, status
    assert_includes error, "exceeds"
  end

  def test_quoting_empty_arguments_and_expansion_boundaries
    assert_output("<one two>\n<one>\n<two>\n<>\n<$value>\n<one two!>\n", <<~'SHELL')
      value='one two'
      printf '<%s>\n' "$value" $value "" '$value' "$value"\!
    SHELL
  end

  def test_globs_preserve_quoted_wildcards_and_unmatched_patterns
    File.write(File.join(@directory, "b.rb"), "")
    File.write(File.join(@directory, "a.rb"), "")
    assert_output("a.rb\nb.rb\n*.rb\nmissing*\n", "printf '%s\\n' *.rb '*.rb' missing*")
  end

  def test_variable_export_and_temporary_environment_are_distinct
    ruby = Shellwords.escape(RbConfig.ruby)
    assert_output("absent\nlocal\ntemporary\nlocal\n", <<~SHELL)
      VALUE=local
      #{ruby} -e 'puts ENV.fetch("VALUE", "absent")'
      export VALUE
      #{ruby} -e 'puts ENV.fetch("VALUE", "absent")'
      VALUE=temporary #{ruby} -e 'puts ENV.fetch("VALUE", "absent")'
      printf '%s\\n' "$VALUE"
    SHELL
    assert_equal "local", @runtime.environment["VALUE"]
  end

  def test_export_assignment_does_not_split_or_glob
    assert_output("one two *", "value='one two *'; export RESULT=$value; printf '%s' \"$RESULT\"")
    assert_equal "one two *", @runtime.environment["RESULT"]
  end

  def test_sequences_boolean_lists_negation_and_status
    assert_output("fallback:1:0", 'false && printf no; false || printf fallback; ! true; printf ":%s" "$?"; ! false; printf ":%s" "$?"')
  end

  def test_if_elif_else_and_nested_control_flow
    assert_output("right", <<~SHELL)
      if false; then
        printf wrong
      elif true; then
        if false; then printf wrong; else printf right; fi
      else
        printf wrong
      fi
    SHELL
  end

  def test_loops_break_continue_and_until
    assert_output("ab:done", <<~SHELL)
      for item in a skip b stop c; do
        if [ "$item" = skip ]; then continue; fi
        if [ "$item" = stop ]; then break; fi
        printf '%s' "$item"
      done
      value=start
      while [ "$value" = start ]; do value=next; done
      until [ "$value" = done ]; do value=done; done
      printf ':%s' "$value"
    SHELL
  end

  def test_functions_persist_and_restore_positional_arguments
    assert_output("", 'report() { printf "<%s>" "$@"; return 7; }')
    assert_output("<one two><>7:outer", 'set -- outer; report "one two" ""; printf "%s:%s" "$?" "$1"')
  end

  def test_empty_quoted_at_does_not_create_an_argument
    assert_output("0:2:a b", 'count() { printf "%s" "$#"; }; count "$@"; set -- "a b" ""; printf ":"; count "$@"; printf ":%s" "$1"')
  end

  def test_default_for_arguments_shift_and_multi_digit_parameters
    assert_output("ab:1:b:ten", 'set -- a b; for item; do printf "%s" "$item"; done; shift; printf ":%s:%s" "$#" "$1"; set -- 1 2 3 4 5 6 7 8 9 ten; printf ":%s" "${10}"')
  end

  def test_pipeline_runs_concurrently_and_isolates_builtin_state
    assert_output("AB:original", "value=original; printf ab | tr a-z A-Z; printf x | value=child; printf ':%s' \"$value\"")
    status, output, error = execute("yes x | head -n 20000 | wc -l")
    assert_equal 0, status, error
    assert_equal 20000, output.to_i
  end

  def test_ordered_redirection_input_append_and_descriptor_duplication
    ruby = Shellwords.escape(RbConfig.ruby)
    command = "#{ruby} -e 'STDOUT.write(\"out\"); STDERR.write(\"err\")'"
    assert_output("", "#{command} >combined 2>&1")
    assert_equal "outerr".chars.sort, File.read(File.join(@directory, "combined")).chars.sort
    assert_output("err", "#{command} 2>&1 >onlyout")
    assert_equal "out", File.read(File.join(@directory, "onlyout"))
    assert_output("outmore", "printf more >>onlyout; cat <onlyout")
  end

  def test_group_redirection_and_function_redirection
    assert_output("ab", "{ printf a; printf b; } >result; cat result")
    assert_output("function", "f() { printf function; }; f >result; cat result")
  end

  def test_native_script_arguments_exit_and_state_isolation
    File.write(File.join(@directory, "script.kwsh"), <<~'SHELL')
      VALUE=child
      printf '%s:%s:%s' "$0" "$#" "$1"
      exit 7
      printf unreachable
    SHELL
    assert_output("script.kwsh:1:a b:7:parent", 'VALUE=parent; kwsh script.kwsh "a b"; printf ":%s:%s" "$?" "$VALUE"')
    refute @runtime.exited
  end

  def test_exit_stops_the_current_program
    assert_output("before", "printf before; exit 9; printf after", status: 9)
    assert @runtime.exited
  end

  def test_aliases_are_available_inside_compound_programs
    assert_output("ab", "alias say='printf %s'\nfor value in a b; do say \"$value\"; done")
  end

  def test_parse_errors_reject_the_whole_program_before_side_effects
    ["echo $(if)", "echo `if`", "echo $((1+=2))", "cat <<EOF\ntext", "echo x & &", "(echo x", "case x in x echo x;; esac", "[[ -f ]]", "echo ${x:1}", "echo $'unclosed"].each do |unsupported|
      status, _, error = execute("printf touched >sentinel; #{unsupported}")
      assert_equal 2, status, unsupported
      refute File.exist?(File.join(@directory, "sentinel")), unsupported
      refute_empty error
    end
  end

  def test_incomplete_input_is_distinct_from_invalid_syntax
    ["if true; then", "for x in a; do", "f() {", "printf 'hello", "printf x |"].each do |source|
      assert_raises(Kward::NativeShell::IncompleteInput, source) { Kward::NativeShell::Parser.parse(source) }
    end
    assert_raises(Kward::NativeShell::SyntaxError) { Kward::NativeShell::Parser.parse("echo x & &") }
  end

  def test_unsupported_builtins_and_read_options_are_explicit_errors
    ["exec --unsupported true", "set -o unknown", "read -p prompt", "read", "break", "return"].each do |source|
      status, output, error = execute(source)
      assert_equal 2, status, source
      assert_empty output
      refute_empty error
    end
  end

  def test_executable_text_uses_an_isolated_native_interpreter
    path = File.join(@directory, "native-text")
    File.write(path, <<~'SHELL')
      printf '%s|%s|%s|%s|%s|' "$0" "$1" "$EXPORTED" "$PRIVATE" "$((5 + 2) )"
      pwd -P
      EXPORTED=child
      cd /
      exit 7
    SHELL
    File.chmod(0o700, path)
    argument = 'two words; printf injected >sentinel'
    @runtime.run("export EXPORTED=parent; PRIVATE=secret")
    { "./native-text" => "./native-text", "PATH=.:$PATH native-text" => "native-text", "command ./native-text" => "./native-text" }.each do |command, name|
      status, output, error = execute("#{command} #{Shellwords.escape(argument)}")
      assert_equal 7, status, error
      assert_empty error
      assert_equal "#{name}|#{argument}|parent||7|#{File.realpath(@directory)}\n", output
      assert_equal File.realpath(@directory), @runtime.cwd
      assert_equal "parent", @runtime.variables["EXPORTED"]
      refute File.exist?(File.join(@directory, "sentinel"))
    end
  end

  def test_executable_text_accepts_empty_files_and_long_first_lines
    path = File.join(@directory, "native-text")
    { "" => "", "##{'x' * 5000}\nprintf native" => "native" }.each do |source, expected|
      File.write(path, source)
      File.chmod(0o700, path)
      assert_output(expected, "./native-text")
    end
  end

  def test_executable_text_rejects_unsupported_syntax_without_trying_another_shell
    path = File.join(@directory, "native-text")
    File.write(path, "printf '%s' \"$((values[0] + 1))\"\n")
    File.chmod(0o700, path)
    status, output, error = execute("./native-text")
    assert_equal 2, status
    assert_empty output
    assert_includes error, "unsupported token in arithmetic expression"
  end

  def test_executable_text_keeps_redirections_input_and_umask
    path = File.join(@directory, "native-text")
    File.write(path, "read value <&3\nprintf '%s' \"$value\" >&4\nprintf error >&2\nprintf created >created\n")
    File.chmod(0o700, path)
    File.write(File.join(@directory, "input"), "payload\n")
    status, output, error = execute("umask 077; ./native-text 3<input 4>output 2>errors")
    assert_equal 0, status, error
    assert_empty output
    assert_empty error
    assert_equal "payload", File.read(File.join(@directory, "output"))
    assert_equal "error", File.read(File.join(@directory, "errors"))
    assert_equal 0o600, File.stat(File.join(@directory, "created")).mode & 0o777
  end

  def test_executable_text_bootstrap_does_not_load_ruby_environment_code
    path = File.join(@directory, "native-text")
    File.write(path, "printf native\n")
    File.chmod(0o700, path)
    File.write(File.join(@directory, "injected.rb"), "abort 'RUBYOPT executed'")
    File.write(File.join(@directory, "shellwords.rb"), "abort 'RUBYLIB executed'")
    assert_output("native", "RUBYOPT=-rinjected RUBYLIB=#{Shellwords.escape(@directory)} ./native-text")
  end

  def test_explicit_shebang_still_selects_its_interpreter
    path = File.join(@directory, "ruby-script")
    File.write(path, "#!#{RbConfig.ruby}\nprint ARGV.fetch(0).upcase\n")
    File.chmod(0o700, path)
    assert_output("RUBY", "./ruby-script ruby")
  end

  def test_long_boolean_lists_do_not_require_recursive_evaluation
    assert_output("", Array.new(2_000, "true").join(" && "))
  end

  def test_builtin_errors_follow_stderr_redirection
    status, output, error = execute("cd missing 2>errors")
    assert_equal 2, status
    assert_empty output
    assert_empty error
    assert_includes File.read(File.join(@directory, "errors")), "no such directory"

    status, _, error = execute("pwd >&-")
    assert_equal 2, status
    assert_includes error, "standard output is closed"
  end

  def test_expanded_values_are_not_reparsed_as_source
    assert_output("; printf injected >sentinel", %q{value='; printf injected >sentinel'; printf '%s' "$value"})
    refute File.exist?(File.join(@directory, "sentinel"))
  end

  def test_binary_looking_invalid_executables_cannot_trigger_shell_fallback
    path = File.join(@directory, "invalid-binary")
    ["\x7fELF\nprintf touched >sentinel\n", "\0\nprintf touched >sentinel\n"].each do |content|
      File.binwrite(path, content)
      File.chmod(0o700, path)
      status, _, _ = execute("./invalid-binary")
      assert_equal 126, status
      refute File.exist?(File.join(@directory, "sentinel"))
    end
  end

  def test_native_scripts_have_their_own_process_and_no_private_parent_variables
    File.write(File.join(@directory, "child.kwsh"), 'printf "%s:%s" "$$" "$PRIVATE"')
    @runtime.run("PRIVATE=parent")
    status, output, error = execute("kwsh child.kwsh")
    assert_equal 0, status, error
    refute_equal Process.pid.to_s, output.split(":").first
    assert output.end_with?(":"), output
  end

  def test_nonexecutable_path_entries_return_126
    File.write(File.join(@directory, "not-executable"), "unused")
    status, _, error = execute("PATH=.:$PATH not-executable")
    assert_equal 126, status
    refute_empty error
  end

  def test_excessive_conditional_nesting_is_an_error_not_a_stack_overflow
    source = "if false; then :; " + "elif false; then :; " * 101 + "fi"
    status, _, error = execute(source)
    assert_equal 2, status
    assert_includes error, "nesting exceeds"
  end

  def test_parameter_defaults_distinguish_unset_empty_and_populated_values
    assert_output("fallback|fallback||fallback|yes|yes|alternate||alternate", <<~'SHELL')
      unset value
      printf '%s|%s|' "${value-fallback}" "${value:-fallback}"
      value=
      printf '%s|%s|' "${value-fallback}" "${value:-fallback}"
      value=yes
      printf '%s|%s|%s|' "${value-fallback}" "${value:-fallback}" "${value:+alternate}"
      value=
      printf '%s|%s' "${value:+alternate}" "${value+alternate}"
    SHELL
  end

  def test_parameter_operands_are_nested_lazy_and_quote_preserving
    assert_output("yes|fallback|a b|}|'literal'|7", <<~'SHELL')
      value=yes
      printf '%s|' "${value:-${unused:=bad}}"
      printf '%s|' "${unused-fallback}"
      printf '%s|' ${missing:-"a b"}
      printf '%s|' "${missing:-\}}"
      printf '%s|' "${missing:-'literal'}"
      printf '%s' "${missing:-$((5 + 2))}"
      : "${value:-$((1 / 0))}" "${missing:+$((1 / 0))}"
    SHELL
  end

  def test_parameter_assignment_preserves_the_unsplit_value_and_export_attribute
    assert_output("<a><b>|a b|new|hidden|", <<~'SHELL')
      export value
      printf '<%s>' ${value:=a b}
      printf '|%s|' "$value"
      value=
      : "${value=unchanged}"
      : "${value:=new}"
      printf '%s|%s|' "$value" "${private=hidden}"
    SHELL
    assert_equal "new", @runtime.environment["value"]
    refute @runtime.environment.key?("private")
  end

  def test_parameter_operands_preserve_positional_arguments_with_custom_ifs
    assert_output("<a><b>|a:b|<ab>|<><>|<fallback>", <<~'SHELL')
      set -- a b
      IFS=:
      printf '<%s>' "${value:=$@}"
      printf '|%s|' "$value"
      IFS=
      printf '<%s>' "${missing:-$@}"
      printf '|'
      set -- ''
      printf '<%s>' "${@:-fallback}" "${*:-fallback}"
      printf '|'
      set --
      printf '<%s>' "${@:-fallback}"
    SHELL
  end

  def test_parameter_error_aborts_submission_before_redirection_or_later_commands
    status, output, error = execute('printf "%s" "${missing:?provide a value}" >sentinel; printf later')
    assert_equal 2, status
    assert_empty output
    assert_includes error, "missing: provide a value"
    refute File.exist?(File.join(@directory, "sentinel"))
    status, _, error = execute(': "${1:=no}"')
    assert_equal 2, status
    assert_includes error, "cannot assign"
  end

  def test_parameter_lengths_and_pattern_removal
    assert_output("5|b/c|c|a/b|a|a/b/c|2|one:two", <<~'SHELL')
      value=a/b/c
      printf '%s|%s|%s|%s|%s|%s|' "${#value}" "${value#*/}" "${value##*/}" "${value%/*}" "${value%%/*}" "${value#'*/'}"
      set -- preone pretwo
      printf '%s|' "${#@}"
      printf '%s:%s' "${@#pre}"
    SHELL
    assert_output("3", 'LC_ALL=C.UTF-8; value="é猫a"; printf "%s" "${#value}"')
  end

  def test_parameter_expansion_rejects_invalid_or_excessive_nesting_before_side_effects
    ['${}', '${x:1}', '${#x:-bad}', '${x:-$(if)}', '${x:-' * 101 + 'a' + '}' * 101].each do |expression|
      status, _, error = execute("printf touched >sentinel; echo #{expression}")
      assert_equal 2, status, expression
      refute_empty error
      refute File.exist?(File.join(@directory, "sentinel"))
    end
    assert_raises(Kward::NativeShell::IncompleteInput) { Kward::NativeShell::Parser.parse('echo ${x:-${y:-a}') }
  end

  def test_custom_ifs_splits_only_expanded_text_and_preserves_empty_fields
    assert_output("<><a><><b>|<literal:colon><a><b>|<a:b>|< a b ><a><b>", <<~'SHELL')
      IFS=:
      value=:a::b:
      printf '<%s>' $value
      printf '|'
      value=a:b
      printf '<%s>' literal:colon $value
      printf '|'
      IFS=
      printf '<%s>' $value
      printf '|'
      unset IFS
      value=' a b '
      joined=$value
      printf '<%s>' "$joined" $value
    SHELL
  end

  def test_mixed_ifs_whitespace_and_nonwhitespace_separators
    assert_output("<><a><><b>", "IFS=' :'; value=' : a : : b : '; printf '<%s>' $value")
    assert_output("<prea><bpost>", "IFS=:; value=a:b; printf '<%s>' pre${value}post")
    assert_output("<a><b>", "IFS=2; printf '<%s>' a$((2))b")
  end

  def test_empty_quotes_preserve_an_empty_word_without_creating_extra_split_fields
    assert_output("2:<a><b>|2:<a><b>|1:<>", <<~'SHELL')
      value=' a b '
      set -- ""$value
      printf '%s:' "$#"; printf '<%s>' "$@"
      set -- $value""
      printf '|%s:' "$#"; printf '<%s>' "$@"
      value=' '
      set -- ""$value
      printf '|%s:' "$#"; printf '<%s>' "$@"
    SHELL
  end

  def test_star_uses_first_ifs_character_while_quoted_at_preserves_arguments
    assert_output("<a:b><a><b>|<ab><a><b>|<a b>", <<~'SHELL')
      set -- a b
      IFS=:
      printf '<%s>' "$*" "$@"
      printf '|'
      IFS=
      printf '<%s>' "$*" "$@"
      printf '|'
      unset IFS
      printf '<%s>' "$*"
    SHELL
    assert_output("0:1", 'set --; count() { printf "%s" "$#"; }; count "$@"; printf :; count ""')
  end

  def test_case_patterns_quoting_alternatives_nesting_and_status
    assert_output("nested:0:1", <<~'SHELL')
      value='.hidden/path.rb'
      case "$value" in
        '*.rb') printf wrong ;;
        (*.txt|*.rb)
          case x in x) printf nested;; esac
          ;;
        *) printf wrong ;;
      esac
      case unmatched in x) false;; esac
      printf ':%s' "$?"
      case x in x) false;; esac
      printf ':%s' "$?"
    SHELL
    assert_output("literal", 'case "*" in "*") printf literal;; esac')
    assert_output("", 'case x in esac; case x in x) ;; esac')
  end

  def test_case_and_parameter_patterns_share_bracket_classes_and_escape_rules
    assert_output("digit:abc:star:hyphen", <<~'SHELL')
      case 3 in [[:digit:]]) printf digit;; esac
      value=3abc
      printf ':%s' "${value#[[:digit:]]}"
      match='\*'
      case '*' in $match) printf :star;; esac
      match='[a\-c]'
      case - in $match) printf :hyphen;; esac
    SHELL
  end

  def test_case_expands_only_patterns_needed_to_find_a_match
    assert_output("yes", 'case x in x) printf yes;; ${missing:?bad}) printf no;; esac')
    assert_output("yes", 'match="a*"; case abc in "$match") printf no;; $match) printf yes;; esac')
    assert_raises(Kward::NativeShell::IncompleteInput) { Kward::NativeShell::Parser.parse('case x in x) echo x;;') }
  end

  def test_read_raw_lines_empty_ifs_eof_and_temporary_assignment
    File.write(File.join(@directory, "input"), "  a\\b  \nlast")
    assert_output("<  a\\b  ><last>:0", <<~'SHELL')
      unset IFS
      count=0
      while IFS= read -r line || [ -n "$line" ]; do
        printf '<%s>' "$line"
        count=$((count + 1))
      done < input
      printf ':%s' "${IFS+set}0"
    SHELL
    assert_equal "2", @runtime.variables["count"]
    refute @runtime.variables.key?("IFS")
  end

  def test_read_fields_final_remainder_and_backslash_continuation
    File.write(File.join(@directory, "input"), "  one\\ two \\\n three  four  \n")
    assert_output("<one two><three  four>", 'read first rest < input; printf "<%s><%s>" "$first" "$rest"')
    File.write(File.join(@directory, "input"), "one:two:: \n")
    assert_output("<one><two::>", 'IFS=" :" read first rest < input; printf "<%s><%s>" "$first" "$rest"')
    File.write(File.join(@directory, "input"), "one:two:\n")
    assert_output("<one:two:>", 'IFS=: read first < input; printf "<%s>" "$first"')
  end

  def test_read_eof_assigns_partial_input_and_clears_unused_variables
    File.write(File.join(@directory, "input"), "first")
    assert_output("1:<first><>", 'second=old; read first second < input; printf "%s:<%s><%s>" "$?" "$first" "$second"')
    assert_output("1:<>", 'first=old; read first; printf "%s:<%s>" "$?" "$first"')
  end

  def test_read_does_not_consume_input_belonging_to_the_next_external_command
    File.write(File.join(@directory, "input"), "first\nsecond\n")
    assert_output("first:second\n", '{ read first; printf "%s:" "$first"; cat; } < input')
  end

  def test_read_validates_arguments_before_consuming_input_and_uses_stderr_redirection
    File.write(File.join(@directory, "input"), "first\n")
    status, output, error = execute('{ read good bad-name 2>errors; cat; } < input')
    assert_equal 0, status
    assert_equal "first\n", output
    assert_empty error
    assert_includes File.read(File.join(@directory, "errors")), "invalid variable name"
    status, _, error = execute('read value <&-')
    assert_equal 2, status
    assert_includes error, "standard input is closed"
  end

  def test_subshells_and_substitutions_keep_parent_state_and_shell_pid
    assert_output("child:parent:yes", <<~'SHELL')
      value=parent
      result=$(value=child; printf '%s\n\n' "$value")
      printf '%s:%s:' "$result" "$value"
      pid=$$
      (value=isolated; [ "$$" = "$pid" ]) && printf yes
    SHELL
    assert_equal "parent", @runtime.variables["value"]
  end

  def test_command_substitution_handles_nested_syntax_quotes_backticks_and_status
    assert_output("nested:legacy:7:0", <<~'SHELL')
      printf '%s:' "$(case x in x) printf '%s' "$(printf nested)";; esac)"
      printf '%s:' "`printf legacy`"
      result=$(exit 7)
      printf '%s:' "$?"
      printf '%s' "$(printf '%s' 0)"
    SHELL
    assert_output("<a><b>|<a b>", 'printf "<%s>" $(printf "a b\n"); printf "|"; printf "<%s>" "$(printf "a b\n")"')
    assert_output("safe", 'value=safe; printf "%s" "${value:-$(printf bad >sentinel)}"')
    refute File.exist?(File.join(@directory, "sentinel"))
  end

  def test_substitution_drains_large_output_and_does_not_reparse_captured_text
    assert_output("199999", 'value=$(yes x | head -n 100000); printf "%s" "${#value}"')
    assert_output('$(touch sentinel)', %q{printf '%s' "$(printf '%s' '$(touch sentinel)')"})
    refute File.exist?(File.join(@directory, "sentinel"))
  end

  def test_command_substitution_rejects_oversized_and_nul_output
    status, output, error = execute('value=$(yes x | head -c 16777217)')
    assert_equal 2, status
    assert_empty output
    assert_includes error, "command substitution exceeds"
    status, _, error = execute(%q{value=$(printf '\000')})
    assert_equal 2, status
    assert_includes error, "NUL bytes"
    assert_output("okay", 'printf okay')
  end

  def test_process_substitution_handles_readers_writers_and_cleanup
    assert_output("inout", 'cat <(printf in); printf out > >(cat)')
    assert_output("ab", 'cat <(printf a) <(printf b)')
    assert_output("ok", 'true <(yes x); printf ok')
  end

  def test_extended_arithmetic_and_arithmetic_for_use_lazy_native_evaluation
    assert_output("512:1:3:3:7:0:1:15:4", <<~'SHELL')
      value=1
      printf '%s:%s:%s:%s:' "$((2**3**2))" "$((value++))" "$((++value))" "$value"
      printf '%s:%s:%s:' "$((1 ? 7 : 1/0))" "$((0 && (value=9)))" "$((1 || 1/0))"
      printf '%s:%s' "$((value += 12))" "$((~0 & 4))"
    SHELL
    assert_output("02:4", 'for ((i=0; i<4; i++)); do ((i % 2)) && continue; printf "%s" "$i"; done; printf ":%s" "$i"')
    assert_output("3", 'value="1 + 2"; printf "%s" "$((value))"')
  end

  def test_braces_expand_source_only_with_nested_choices_and_numeric_sequences
    assert_output("<xa><xb><xc><03><02><01><a><c><e><{a,b}>", <<~'SHELL')
      literal='{a,b}'
      printf '<%s>' x{a,{b,c}} {03..01} {a..e..2} "$literal"
    SHELL
    status, _, error = execute('printf "%s" {1..1000000}')
    assert_equal 2, status
    assert_includes error, "brace expansion exceeds"
  end

  def test_here_documents_expand_lazily_and_preserve_quoted_delimiters
    assert_output("hello world 7\n$value $(printf bad)\n", <<~'SHELL')
      value=world
      cat <<EOF
      hello $value $(printf 7)
      EOF
      cat <<'EOF'
      $value $(printf bad)
      EOF
      if false; then
        cat <<EOF
      $(printf bad >sentinel)
      EOF
      fi
    SHELL
    refute File.exist?(File.join(@directory, "sentinel"))
    assert_output("second\n", "cat <<ONE <<-TWO\nfirst\nONE\n\tsecond\n\tTWO\n")
    assert_output("nested", "printf '%s' \"$(cat <<EOF\nnested\nEOF\n)\"")
  end

  def test_high_descriptors_are_mapped_without_clobbering_ruby_internal_descriptors
    ruby = Shellwords.escape(RbConfig.ruby)
    assert_output("three:nine", "printf three 3>&1 >&3; #{ruby} -e 'IO.for_fd(9).write(\":nine\")' 9>&1")
    assert_output("data", 'printf data 4<>buffer >&4; cat buffer')
    assert_output("replacement", 'printf first >buffer; printf replacement >|buffer; cat buffer')
    status, _, error = execute('printf no >&9')
    assert_equal 2, status
    assert_includes error, "bad file descriptor"
  end

  def test_array_declarations_append_and_read_array_keep_values_separate
    File.write(File.join(@directory, "array-input"), "a:b::c\n")
    assert_output("<first><second><third!>|<a><b><><c>", <<~'SHELL')
      declare -a items=(first second)
      items+=(third)
      items[2]+=!
      printf '<%s>' "${items[@]}"
      IFS=: read -r -a items <array-input
      printf '|'
      printf '<%s>' "${items[@]}"
    SHELL
    assert_output("value", 'declare -A options=([key]=value); printf "%s" "${options[key]}"')
  end

  def test_arrays_support_sparse_indices_associative_keys_and_argument_boundaries
    assert_output("<one><two three><four>|3|changed|4|0:1:2:7", <<~'SHELL')
      values=(one "two three" four)
      printf '<%s>' "${values[@]}"
      printf '|%s|' "${#values[@]}"
      i=1
      values[$i]=changed
      values[7]=last
      printf '%s|%s|' "${values[1]}" "${#values[@]}"
      IFS=:
      printf '%s' "${!values[*]}"
    SHELL
    assert_output("Kai Wood:captain:2:captain", <<~'SHELL')
      declare -A person
      person=([name]="Kai Wood" [role]=captain)
      key=role
      printf '%s:%s:%s:' "${person[name]}" "${person[$key]}" "${#person[@]}"
      unset 'person[name]'
      printf '%s' "${person[role]}"
    SHELL
  end

  def test_array_values_are_not_reparsed_as_commands_and_subshell_changes_are_isolated
    assert_output('$(touch sentinel):first:last', <<~'SHELL')
      values=(first last)
      payload='$(touch sentinel)'
      values[5]=$payload
      (values[0]=child)
      printf '%s:%s:%s' "${values[5]}" "${values[0]}" "${values[1]}"
    SHELL
    refute File.exist?(File.join(@directory, "sentinel"))
    assert_output("0", 'values=(); count() { printf "%s" "$#"; }; count "${values[@]}"')
    assert_output("last", 'values=([4]=first [9]=last); printf "%s" "${values[-1]}"')
  end

  def test_double_brackets_preserve_words_and_short_circuit_expansion
    assert_output("pattern:literal:numeric:regex:lazy", <<~'SHELL')
      value='one two'
      [[ $value == one* ]] && printf pattern
      [[ $value != 'one*' ]] && printf :literal
      [[ 2+3 -eq 5 && ! -z "$value" ]] && printf :numeric
      [[ abc =~ ^a.* ]] && printf :regex
      [[ yes || ${missing:?not evaluated} ]] && printf :lazy
    SHELL
    assert_output("ab:a:b", '[[ ab =~ ^(a)(b)$ ]] && printf "%s:%s:%s" "${BASH_REMATCH[0]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"')
    assert_output("file", 'printf data >input; [[ -f input && -s input && ( -r input || -z x ) ]] && printf file')
    status, _, error = execute('[[ x =~ "[" ]]')
    assert_equal 1, status
    assert_empty error
  end

  def test_globstar_is_opt_in_and_braces_precede_substitution
    FileUtils.mkdir_p(File.join(@directory, "a", "b"))
    %w[top.rb a/one.rb a/b/two.rb].each { |path| File.write(File.join(@directory, path), "") }
    assert_output("<a/one.rb>|<a/b/two.rb><a/one.rb><top.rb>", 'printf "<%s>" **/*.rb; printf "|"; shopt -s globstar; printf "<%s>" **/*.rb')
    assert_output("aab", 'printf "%s" $(printf a){,b}')
    assert_output("<a><b>", 'printf "<%s>" ""{a,b}')
  end

  def test_dot_sourcing_and_eval_use_native_state_and_restore_arguments
    File.write(File.join(@directory, "library.kwsh"), 'VALUE=$1; helper() { printf "%s" "$VALUE"; }; return 7; printf bad')
    assert_output("7:outer:inner:3", <<~'SHELL')
      set -- outer
      . ./library.kwsh inner
      printf '%s:%s:' "$?" "$1"
      helper
      eval 'value=$((1 + 2))'
      printf ':%s' "$value"
    SHELL
    refute @runtime.exited
  end

  def test_readonly_command_lookup_and_getopts_keep_interpreter_state
    assert_output("external:pwd\navalue:3", <<~'SHELL')
      printf() { command printf '%s' external; }
      printf
      command printf ':'
      command -v pwd
      unset -f printf
      set -- -a -bvalue rest
      while getopts 'ab:' option; do
        case "$option" in a) printf a;; b) printf '%s' "$OPTARG";; esac
      done
      printf ':%s' "$OPTIND"
    SHELL
    assert_output("", 'readonly fixed=original')
    status, _, error = execute('fixed=changed')
    assert_equal 2, status
    assert_includes error, "readonly variable"
    assert_equal "original", @runtime.variables["fixed"]
    status, _, error = execute('unset fixed')
    assert_equal 2, status
    assert_includes error, "readonly variable"
  end

  def test_command_lookup_does_not_report_missing_or_nonexecutable_files
    File.write(File.join(@directory, "plain-file"), "not executable")
    assert_output("1:1", 'command -v ./missing; printf "%s:" "$?"; command -v ./plain-file; printf "%s" "$?"')
  end

  def test_getopts_silent_errors_reset_and_explicit_arguments
    assert_output("?:z|::b|a|a", <<~'SHELL')
      getopts ':ab:' option -z
      printf '%s:%s|' "$option" "$OPTARG"
      OPTIND=1
      getopts ':ab:' option -b
      printf '%s:%s|' "$option" "$OPTARG"
      OPTIND=1
      getopts 'ab' option -ab
      printf '%s|' "$option"
      OPTIND=1
      getopts 'ab' option -ab
      printf '%s' "$option"
    SHELL
  end

  def test_shell_options_handle_failure_context_and_pipeline_status
    assert_output("okay:end:1", 'set -e; false || printf okay; if false; then printf bad; fi; ! true; printf :end; set -o pipefail; false | true || printf ":%s" "$?"')
    assert_output("", 'set -e; false; printf bad', status: 1)
    assert @runtime.exited
  end

  def test_nounset_noglob_noclobber_and_allexport_are_explicit_options
    File.write(File.join(@directory, "one.rb"), "original")
    assert_output("*.rb:default", 'set -fu; printf "%s:%s" *.rb "${unset:-default}"')
    status, _, error = execute('printf "%s" "$unset"')
    assert_equal 2, status
    assert_includes error, "unbound variable"
    status, _, error = execute('set -C; printf bad >one.rb')
    assert_equal 2, status
    assert_equal "original", File.read(File.join(@directory, "one.rb"))
    assert_output("", 'printf replacement >|one.rb; set -a; visible=yes; set +a; private=no')
    assert_equal "yes", @runtime.environment["visible"]
    refute @runtime.environment.key?("private")
    assert_equal "replacement", File.read(File.join(@directory, "one.rb"))
  end

  def test_umask_controls_redirects_and_external_children_without_changing_host_mask
    original = File.umask
    ruby = Shellwords.escape(RbConfig.ruby)
    assert_output("0077\nu=rwx,g=,o=\n", "umask 077; umask; umask -S; printf x >private; #{ruby} -e 'File.write(\"child-private\", \"x\")'")
    assert_equal 0o600, File.stat(File.join(@directory, "private")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(@directory, "child-private")).mode & 0o777
    assert_equal original, File.umask
    assert_output("0022\n", 'umask u=rwx,g=rx,o=rx; umask')
  end

  def test_noexec_checks_syntax_without_running_later_commands
    assert_output("", 'set -n; printf bad >sentinel')
    refute File.exist?(File.join(@directory, "sentinel"))
    status, _, error = execute('if')
    assert_equal 2, status
    refute_empty error
  end

  def test_read_custom_delimiters_dollar_quotes_and_multilevel_loop_control
    File.binwrite(File.join(@directory, "input"), "one\0two\0")
    assert_output("<one><two>|a\nb|2", <<~'SHELL')
      while IFS= read -r -d '' item; do printf '<%s>' "$item"; done <input
      printf '|%s|' $'a\nb'
      count=0
      for first in a b; do
        for second in c d; do
          ((count++))
          continue 2
        done
      done
      printf '%s' "$count"
    SHELL
    assert_output("once", 'for a in 1 2; do for b in 1 2; do printf once; break 2; done; done')
  end

  def test_byte_escapes_preserve_utf8_and_nul_values_cannot_cross_execve
    assert_output("é:é", %q{printf '%s:%s' $'\xC3\xA9' $'\u00E9'})
    File.binwrite(File.join(@directory, "nul-input"), "bad\0value\n")
    status, _, error = execute('IFS= read -r value <nul-input; printf "%s" "$value" >sentinel')
    assert_equal 2, status
    refute_empty error
    assert_equal "", File.read(File.join(@directory, "sentinel"))
  end

  def test_unknown_command_and_missing_executable_status
    status, _, error = execute("kwsh-nonexistent-command")
    assert_equal 127, status
    assert_includes error, "command not found"
  end
end
