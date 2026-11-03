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
    ["5 +", "1=2", "1++", "2**3", "1; touch sentinel", "$(touch sentinel)", "`touch sentinel`", "1.5", "08", "1 << 2", "1 < 2"].each do |expression|
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
    ["echo $((1 / 0)) >sentinel", "echo $((1 % 0)) >sentinel", "value='$(touch sentinel)'; echo $((value))", "value='1 + 2'; echo $((value))"].each do |source|
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
    assert_output("ab", "alias say='printf %s'; for value in a b; do say \"$value\"; done")
  end

  def test_parse_errors_reject_the_whole_program_before_side_effects
    ["echo $(pwd)", "echo `pwd`", "echo $((1+=2))", "cat <<EOF\ntext\nEOF", "echo x &", "(echo x)", "case x in x echo x;; esac", "[[ -f x ]]", "echo ${x:1}", "echo $'x'"].each do |unsupported|
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
    assert_raises(Kward::NativeShell::SyntaxError) { Kward::NativeShell::Parser.parse("echo x &") }
  end

  def test_unsupported_builtins_and_read_options_are_explicit_errors
    ["eval 'printf no'", "set -e", "read -a values", "read", "break", "return"].each do |source|
      status, output, error = execute(source)
      assert_equal 2, status, source
      assert_empty output
      refute_empty error
    end
  end

  def test_executable_text_does_not_fall_back_to_sh
    path = File.join(@directory, "not-a-binary")
    File.write(path, "printf touched >sentinel\n")
    File.chmod(0o700, path)
    status, _, error = execute("./not-a-binary")
    assert_equal 126, status
    assert_includes error, "use kwsh"
    refute File.exist?(File.join(@directory, "sentinel"))
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
    File.binwrite(path, "\x7fELF\nprintf touched >sentinel\n")
    File.chmod(0o700, path)
    status, _, _ = execute("./invalid-binary")
    assert_equal 126, status
    refute File.exist?(File.join(@directory, "sentinel"))
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
    assert_output("3", 'value="é猫a"; printf "%s" "${#value}"')
  end

  def test_parameter_expansion_rejects_invalid_or_excessive_nesting_before_side_effects
    ['${}', '${x:1}', '${#x:-bad}', '${x:-$(touch sentinel)}', '${x:-' * 101 + 'a' + '}' * 101].each do |expression|
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

  def test_unknown_command_and_missing_executable_status
    status, _, error = execute("kwsh-nonexistent-command")
    assert_equal 127, status
    assert_includes error, "command not found"
  end
end
