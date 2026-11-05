require_relative "test_helper"
require "open3"
require "pty"
require "timeout"
require_relative "../lib/kward/shell/script_runner"

class TestNativeShellInvocation < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(*args, env: {}, **options)
    Open3.capture3({ "LC_ALL" => "C", "ENV" => nil, "PS1" => "primary> ", "PS2" => "more> " }.merge(env),
                  RbConfig.ruby, EXECUTABLE, *args, **options)
  end

  def test_required_alias_names_and_restorable_listing_format
    names = %w[1 a!b a%b a,b a-b a@b _ -dash]
    source = names.map { |name| "alias -- #{Shellwords.escape("#{name}=printf '%s' '#{name}|' ")}" }.join("\n")
    source << "\n" << names.join("\n") << "\nalias\n"
    output, error, status = invoke("-c", source)
    assert status.success?, error
    assert_empty error
    values = output.split("|", names.length + 1)
    listing = values.pop
    assert_equal names, values
    listing.lines.each do |line|
      refute line.start_with?("alias ")
      name, value = line.chomp.split("=", 2)
      assert_includes names, name
      assert_equal "printf '%s' '#{name}|' ", Shellwords.split(value).fetch(0)
    end
    restored = listing.lines.map { |line| "alias -- #{line}" }.join + names.join("\n")
    output, error, status = invoke("-c", restored)
    assert status.success?, error
    assert_equal names.map { |name| "#{name}|" }.join, output
    assert_empty error
  end

  def test_alias_lookup_quoting_is_separate_from_command_descriptions
    output, error, status = invoke("-c", "alias sample=\"printf '%s' 'two words'\"\nalias sample\ncommand -v sample\ntype sample\n")
    assert status.success?, error
    assert_empty error
    listing, command, type = output.lines
    assert listing.start_with?("sample=")
    assert_equal "alias #{listing}", command
    assert_equal command, type
  end

  def test_xtrace_expands_assignments_once_before_execution_and_uses_redirected_stderr
    Dir.mktmpdir("native-trace") do |dir|
      output, error, status = invoke("-c", <<~'SHELL', chdir: dir)
        set -x
        >marker 2>redirect-trace
        first=$(printf once >>count; printf value) second=$first 2>trace
        before=$(printf 'expanding\n' >&2; printf ready) printf 'executing\n' >&2
        set +x
        cat trace
        cat count
        printf ':%s:%s' "$first" "$second"
      SHELL
      assert status.success?, error
      assert_equal "+ \n", File.read(File.join(dir, "redirect-trace"))
      assert File.exist?(File.join(dir, "marker"))
      assert_includes output, "+ first=value\n"
      assert_includes output, "+ second=value\n"
      assert output.end_with?("once:value:value")
      expansion = error.index("expanding\n")
      assignment = error.index("+ before=ready\n")
      execution = error.index("\nexecuting\n")
      refute_nil expansion
      refute_nil assignment
      refute_nil execution
      assert_operator expansion, :<, assignment
      assert_operator assignment, :<, execution
      refute_includes error, "+ first=value"
    end
  end

  def test_startup_initializes_ppid_and_optind_in_clean_and_inherited_environments
    source = <<~'SHELL'
      printf '%s:%s\n' "$PPID" "$OPTIND"
      (printf '%s:%s\n' "$PPID" "$OPTIND")
      printf '%s\n' "$(printf '%s:%s' "$PPID" "$OPTIND")"
      getopts a option -a
      printf '%s:%s\n' "$option" "$OPTIND"
    SHELL
    [{}, { "PPID" => "bogus", "OPTIND" => "9" }].each do |env|
      output, error, status = invoke("-c", source, env: { "PATH" => "/usr/bin:/bin" }.merge(env), unsetenv_others: true)
      assert status.success?, error
      assert_equal ("#{Process.pid}:1\n" * 3) + "a:2\n", output
      assert_empty error
    end
  end

  def test_startup_variables_are_available_in_file_and_stdin_modes
    Dir.mktmpdir("native-startup") do |dir|
      file = File.join(dir, "script")
      source = 'printf "%s:%s" "$PPID" "$OPTIND"'
      File.write(file, source)
      [[file], [], ["-s"]].each do |args|
        output, error, status = invoke(*args, stdin_data: source, env: { "PPID" => "0", "OPTIND" => "8" })
        assert status.success?, error
        assert_equal "#{Process.pid}:1", output
        assert_empty error
      end
    end
  end

  def test_subshells_preserve_current_optind_without_resetting_parent_state
    output, error, status = invoke("-c", <<~'SHELL')
      getopts a option -a
      (printf '%s:' "$OPTIND"; OPTIND=1)
      printf '%s:%s' "$(printf '%s' "$OPTIND")" "$OPTIND"
    SHELL
    assert status.success?, error
    assert_equal "2:2:2", output
    assert_empty error
    runtime = Kward::NativeShell::Runtime.new(env: {})
    assert_equal "1", runtime.variables.fetch("OPTIND")
    refute runtime.environment.key?("OPTIND"), "OPTIND must not be exported by default"
  ensure
    runtime&.close
  end

  def test_startup_preserves_valid_logical_pwd_and_exports_it
    Dir.mktmpdir("native-pwd") do |dir|
      physical = File.realpath(dir)
      Dir.mkdir(File.join(dir, "real"))
      logical = File.join(dir, "link")
      File.symlink(File.join(dir, "real"), logical)
      [logical, "#{logical}//"].each do |pwd|
        output, error, status = invoke("-c", <<~'SHELL', env: { "PWD" => pwd }, chdir: logical)
          printf '%s\n' "$PWD"
          pwd -L
          pwd -P
          (printf '%s\n' "$PWD")
          env | grep '^PWD='
          cd ..
          pwd -L
        SHELL
        assert status.success?, error
        assert_equal "#{pwd}\n#{pwd}\n#{physical}/real\n#{pwd}\nPWD=#{pwd}\n#{dir}\n", output
        assert_empty error
      end
    end
  end

  def test_startup_replaces_missing_or_invalid_pwd_with_physical_path
    Dir.mktmpdir("native-pwd") do |dir|
      real = File.join(dir, "real")
      Dir.mkdir(real)
      logical = File.join(dir, "link")
      File.symlink(real, logical)
      file = File.join(dir, "file")
      File.write(file, "not a directory")
      [nil, "", "link", dir, file, "#{dir}/missing", "#{logical}/.", "#{logical}/../real"].each do |pwd|
        output, error, status = invoke("-c", 'printf "%s\n" "$PWD"; pwd -L', env: { "PWD" => pwd }, chdir: logical)
        assert status.success?, error
        assert_equal "#{File.realpath(real)}\n" * 2, output
        assert_empty error
      end
    end
  end

  def test_hosted_startup_keeps_the_explicit_workspace_root
    Dir.mktmpdir("native-hosted-pwd") do |dir|
      other = File.join(dir, "other")
      Dir.mkdir(other)
      logical = File.join(dir, "link")
      File.symlink(dir, logical)
      [other, logical].each do |pwd|
        runtime = Kward::NativeShell::Runtime.new(cwd: dir, env: { "PWD" => pwd }, hosted: true)
        begin
          assert_equal dir, runtime.cwd
          assert_equal dir, runtime.variables.fetch("PWD")
        ensure
          runtime.close
        end
      end
    end
  end

  def test_default_zero_comes_from_invocation_and_explicit_command_names_win
    source = 'printf "<%s>:%s:<%s>" "$0" "$#" "${1-unset}"'
    [["-c", source], [], ["-s"]].each do |args|
      output, error, status = invoke(*args, stdin_data: source)
      assert status.success?, error
      assert_equal "<#{EXECUTABLE}>:0:<unset>", output
      assert_empty error
    end
    ["custom name", ""].each do |name|
      output, error, status = invoke("-c", source, name, "argument")
      assert status.success?, error
      assert_equal "<#{name}>:1:<argument>", output
      assert_empty error
    end
    output, error, status = Open3.capture3(RbConfig.ruby, "./exe/kwsh", "-c", source, chdir: File.expand_path("..", __dir__))
    assert status.success?, error
    assert_equal "<./exe/kwsh>:0:<unset>", output
    assert_empty error
  end

  def test_leading_dash_is_ignored_before_file_and_command_operands
    source = 'printf "<%s>:%s:<%s>" "$0" "$#" "${1-unset}"'
    Dir.mktmpdir("native-operands") do |dir|
      File.write(File.join(dir, "script"), source)
      [["script", "argument"], ["-", "script", "argument"]].each do |args|
        output, error, status = invoke(*args, chdir: dir, stdin_data: "printf wrong-input")
        assert status.success?, error
        assert_equal "<script>:1:<argument>", output
        assert_empty error
      end
    end
    [["-c", "-", source, "name", "argument"], ["-s", "-", "argument"]].each do |args|
      output, error, status = invoke(*args, stdin_data: source)
      assert status.success?, error
      assert_equal "<#{args.first == '-c' ? 'name' : EXECUTABLE}>:1:<argument>", output
      assert_empty error
    end
    output, error, status = invoke("-c", "-", source)
    assert status.success?, error
    assert_equal "<#{EXECUTABLE}>:0:<unset>", output
    assert_empty error
  end

  def test_lone_dash_still_reads_stdin_without_read_ahead
    output, error, status = invoke("-", stdin_data: "read value\npayload\nprintf '%s:%s' \"$0\" \"$value\"\n")
    assert status.success?, error
    assert_equal "#{EXECUTABLE}:payload", output
    assert_empty error
  end

  def test_alias_text_shares_quotes_and_here_documents_with_the_input_stream
    cases = {
      "alias say=\"printf '%s' '\"\nsay hello'\n" => " hello",
      "alias doc='cat <<EOF\nhello\nEOF\n'\ndoc\n" => "hello\n",
      "alias doc='cat <<EOF'\ndoc\nhello\nEOF\n" => "hello\n",
      "alias a='b '\nalias b='printf %s '\nalias word=value\na word\n" => "value"
    }
    cases.each do |source, expected|
      output, error, status = invoke("-c", source)
      assert status.success?, error
      assert_equal expected, output
      assert_empty error
    end
  end

  def test_grouped_invocation_flags_and_options_after_c_or_s
    [["-ec", "printf '%s' \"$1\"", "name", "value"],
     ["-c", "-e", "printf '%s' \"$1\"", "name", "value"],
     ["-s", "-e", "value"]].each do |args|
      output, error, status = invoke(*args, stdin_data: "printf '%s' \"$1\"\n")
      assert status.success?, error
      assert_equal "value", output
      assert_empty error
    end
  end

  def test_interactive_input_recovers_from_errors_without_read_ahead
    output, error, status = invoke("-i", stdin_data: <<~'SHELL')
      readonly x=1
      x=2; printf bad
      read value
      payload
      if true; then
        printf '%s' "$value"
      fi
      exit 7
    SHELL
    assert_equal 7, status.exitstatus
    assert_equal "payload", output
    assert_includes error, "readonly variable"
    assert_includes error, "primary> "
    assert_includes error, "more> "
  end

  def test_interactive_noexec_is_ignored_and_usr2_is_not_reserved
    output, error, status = invoke("-inc", "case $- in *i*) :;; *) exit 9;; esac; trap 'printf signal' USR2; kill -USR2 $$; printf done")
    assert status.success?, error
    assert_equal "signaldone", output
    assert_empty error
  end

  def test_env_startup_is_parameter_expanded_and_interactive_only
    Dir.mktmpdir("native-startup") do |dir|
      File.write(File.join(dir, "startup"), "VALUE=ready\nalias say='printf %s'\n")
      env = { "HOME" => dir, "ENV" => "${HOME}/startup" }
      output, error, status = invoke("-ic", 'say "$VALUE:$1"', "name", "argument", env: env)
      assert status.success?, error
      assert_equal "ready:argument", output
      assert_empty error
      output, error, status = invoke("-c", 'printf "%s" "${VALUE-unset}"', env: env)
      assert status.success?, error
      assert_equal "unset", output
      assert_empty error
    end
  end

  def test_env_does_not_execute_command_substitutions_or_run_with_mismatched_identity
    Dir.mktmpdir("native-startup") do |dir|
      output, error, status = invoke("-ic", "printf safe", env: { "ENV" => "$(touch sentinel)" }, chdir: dir)
      assert status.success?, error
      assert_equal "safe", output
      assert_includes error, "only parameter expansion"
      refute File.exist?(File.join(dir, "sentinel"))
      File.write(File.join(dir, "startup"), "VALUE=unsafe")
      runtime = Kward::NativeShell::Runtime.new(env: { "ENV" => File.join(dir, "startup") })
      original = Process.method(:euid)
      begin
        Process.define_singleton_method(:euid) { Process.uid + 1 }
        Kward::NativeShell::ScriptRunner.load_startup(runtime, input: StringIO.new, output: StringIO.new, error: StringIO.new)
      ensure
        Process.define_singleton_method(:euid, original)
        runtime.close
      end
      refute runtime.variables.key?("VALUE")
    end
  end

  def test_command_option_combinations_and_declaration_context
    output, error, status = invoke("-c", <<~'SHELL')
      value='two words *'
      command -p export RESULT=$value
      printf '<%s>:' "$RESULT"
      PATH=/missing
      command -pv printf
      command -p printf '%s' "$PATH"
    SHELL
    assert status.success?, error
    assert_match(/\A<two words \*>:.*\/printf\n\/missing\z/, output)
    assert_empty error
  end

  def test_declaration_listings_preserve_unset_values_and_accept_double_dash
    output, error, status = invoke("-c", <<~'SHELL')
      unset EXPORTED READONLY
      export -- EXPORTED
      readonly -- READONLY
      export -p | grep '^export EXPORTED'
      readonly -p
      unset -- EXPORTED
      printf '%s' "${EXPORTED-unset}"
    SHELL
    assert status.success?, error
    assert_equal "export EXPORTED\nreadonly READONLY\nunset", output
    assert_empty error
  end

  def test_cdpath_and_grouped_pwd_options
    Dir.mktmpdir("native-cdpath") do |dir|
      Dir.mkdir(File.join(dir, "target"))
      output, error, status = invoke("-c", 'CDPATH=$1; cd target; pwd -LP --', "name", dir)
      assert status.success?, error
      assert_equal "#{dir}/target\n#{File.realpath(dir)}/target\n", output
      assert_empty error
    end
  end

  def test_hash_locations_are_cleared_even_when_path_is_assigned_the_same_value
    Dir.mktmpdir("native-hash") do |dir|
      file = File.join(dir, "utility")
      File.write(file, "exit 0")
      File.chmod(0o700, file)
      output, error, status = invoke("-c", 'PATH=$1; hash utility; hash; PATH=$PATH; hash; hash -r', "name", dir)
      assert status.success?, error
      assert_equal "#{file}\n", output
      assert_empty error
      output, error, status = invoke("-c", 'PATH=$1; set -h; f() { utility; }; hash', "name", dir)
      assert status.success?, error
      assert_equal "#{file}\n", output
    end
  end

  def test_terminal_input_selects_interactive_mode_automatically
    transcript = +""
    pid = nil
    PTY.spawn({ "ENV" => nil, "PS1" => "automatic> " }, RbConfig.ruby, EXECUTABLE) do |reader, writer, child|
      pid = child
      Timeout.timeout(5) do
        transcript << reader.readpartial(1024) until transcript.include?("automatic> ")
        writer.write("printf '%s%s' AU TO; exit 0\n")
        begin
          loop { transcript << reader.readpartial(1024) }
        rescue EOFError, Errno::EIO
          # Closing a PTY can report EIO rather than EOF.
        end
      end
      _, status = Process.wait2(pid)
      pid = nil
      assert status.success?, transcript
    end
    assert_includes transcript, "AUTO"
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  def test_notify_reports_completion_while_waiting_for_interactive_input
    Open3.popen3({ "ENV" => nil, "PS1" => "ready> " }, RbConfig.ruby, EXECUTABLE, "-i") do |input, output, error, worker|
      begin
        Timeout.timeout(5) do
          transcript = +""
          transcript << error.readpartial(1024) until transcript.include?("ready> ")
          input.write("set -b\nsleep 0.2 &\n")
          input.flush
          transcript << error.readpartial(1024) until transcript.include?("Done")
          assert_includes transcript, "Done"
          input.write("exit\n")
          input.close
          assert worker.value.success?
        end
      ensure
        Process.kill("KILL", worker.pid) if worker.alive?
      end
    end
  end

  def test_times_type_verbose_and_unalias_error_status
    output, error, status = invoke("-c", "times; type if; unalias missing; printf 'status:%s' \"$?\"")
    assert status.success?, error
    assert_match(/\A\d+m\d+\.\d+s \d+m\d+\.\d+s\n\d+m\d+\.\d+s \d+m\d+\.\d+s\nif is keyword\nstatus:2\z/, output)
    assert_includes error, "unalias: not found"
    output, error, status = invoke("-v", "-c", "printf hello\nset -\nprintf done\n")
    assert status.success?, error
    assert_equal "hellodone", output
    assert_includes error, "printf hello\n"
    refute_includes error, "printf done"
  end
end
