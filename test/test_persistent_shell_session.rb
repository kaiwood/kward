require_relative "test_helper"

class TestPersistentShellSession < KwardTestCase
  class Sink
    attr_reader :output

    def initialize
      @output = +""
    end

    def write(value)
      @output << value.to_s
    end

    def flush
    end
  end

  def build_shell(dir, **options)
    Kward::PersistentShellSession.new(cwd: dir, shell: "/bin/sh", **options)
  end

  def test_background_jobs_survive_commands_and_are_closed_even_with_ignored_term
    Dir.mktmpdir("persistent-jobs") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent("trap '' TERM; sleep 30 & printf '%s' \"$!\"")
      assert_equal 0, result.exit_status
      pid = Integer(result.output.lines.last.strip)
      assert_equal pid, Process.getpgid(pid)
      assert_includes shell.run_for_agent("jobs -l").output, "Running"
      shell.close
      wait_until(timeout: 2) do
        Process.kill(0, pid)
        false
      rescue Errno::ESRCH
        true
      end
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    ensure
      shell&.close
    end
  end

  def test_stopped_jobs_can_resume_in_background_and_be_waited_for
    Dir.mktmpdir("persistent-jobs") do |dir|
      shell = build_shell(dir)
      assert_equal 0, shell.run_for_agent("sleep 30 &").exit_status
      assert_equal 0, shell.run_for_agent("kill -STOP %1").exit_status
      wait_until(timeout: 2) { shell.run_for_agent("jobs -s").output.include?("Stopped") }
      assert_equal 0, shell.run_for_agent("bg %1").exit_status
      result = shell.run_for_agent("kill -TERM %1; wait %1")
      assert_equal 128 + Signal.list.fetch("TERM"), result.exit_status
      assert_equal 0, shell.run_for_agent(":").exit_status
    ensure
      shell&.close
    end
  end

  def test_terminal_stopped_server_keeps_running_after_background_resume
    Dir.mktmpdir("persistent-background-resume") do |dir|
      shell = build_shell(dir)
      reader, writer = IO.pipe
      sink = Sink.new
      code = <<~'RUBY'
        STDOUT.sync = true
        puts 'ready'
        loop do
          File.write('heartbeat', Process.clock_gettime(Process::CLOCK_MONOTONIC).to_s)
          sleep 0.02
        end
      RUBY
      command = Shellwords.join([RbConfig.ruby, "-e", code])
      result = nil
      thread = Thread.new { result = shell.run_interactive(command, input: reader, sink: sink) }
      path = File.join(dir, "heartbeat")
      wait_until(timeout: 3) { sink.output.include?("ready") && File.exist?(path) }
      writer.write("\x1a")
      writer.flush
      assert thread.join(3), "foreground server did not stop"
      assert_equal 128 + Signal.list.fetch("TSTP"), result.exit_status
      stopped = File.read(path)
      assert_equal 0, shell.run_for_agent("bg").exit_status
      wait_until(timeout: 3) { File.read(path) != stopped }
      sleep 0.1
      resumed = File.read(path)
      wait_until(timeout: 3) { File.read(path) != resumed }
      assert_empty shell.run_for_agent("jobs -s").output.delete_prefix("$ jobs -s\n").strip
    ensure
      shell&.close
      thread&.join(1)
      reader&.close
      writer&.close
    end
  end

  def test_background_server_handles_repeated_requests_while_shell_is_idle
    Dir.mktmpdir("persistent-background-output") do |dir|
      shell = build_shell(dir)
      reader, writer = IO.pipe
      sink = Sink.new
      code = <<~'RUBY'
        require 'socket'
        STDOUT.sync = STDERR.sync = true
        server = TCPServer.new('127.0.0.1', 0)
        File.write('port', server.addr[1].to_s)
        puts 'ready'
        loop do
          client = server.accept
          client.gets
          STDOUT.write('o' * 131_072)
          STDERR.write('e' * 131_072)
          client.puts 'ok'
          client.close
        end
      RUBY
      command = Shellwords.join([RbConfig.ruby, "-e", code])
      thread = Thread.new { shell.run_interactive(command, input: reader, sink: sink) }
      wait_until(timeout: 3) { sink.output.include?("ready") }
      writer.write("\x1a")
      writer.flush
      assert thread.join(3), "foreground server did not stop"
      assert_equal 0, shell.run_for_agent("bg").exit_status

      3.times do
        TCPSocket.open("127.0.0.1", Integer(File.read(File.join(dir, "port")))) do |client|
          client.puts "request"
          assert IO.select([client], nil, nil, 3), "background server blocked writing terminal output"
          assert_equal "ok\n", client.gets
        end
      end
      result = shell.run_for_agent("printf 'foreground still works'")
      assert_equal 0, result.exit_status
      assert_includes result.output, "foreground still works"
    ensure
      shell&.close
      thread&.join(1)
      reader&.close
      writer&.close
    end
  end

  def test_continuous_background_output_does_not_hold_the_prompt
    Dir.mktmpdir("persistent-background-flood") do |dir|
      shell = build_shell(dir, max_output_bytes: 1_024)
      code = <<~'RUBY'
        STDOUT.sync = true
        STDOUT.write('x' * 65_536)
        File.write('flooding', '')
        loop { STDOUT.write('x' * 65_536) }
      RUBY
      command = "#{Shellwords.join([RbConfig.ruby, '-e', code])} & while [ ! -f flooding ]; do sleep 0.01; done"
      thread = Thread.new { shell.run_for_agent(command) }
      assert thread.join(3), "continuous background output prevented command completion"
      assert_includes thread.value.output, "output truncated"
    ensure
      shell&.close
      thread&.join(1)
    end
  end

  def test_terminal_stop_and_foreground_resume_restore_shell_ownership
    Dir.mktmpdir("persistent-jobs") do |dir|
      shell = build_shell(dir)
      reader, writer = IO.pipe
      sink = Sink.new
      command = Shellwords.join([RbConfig.ruby, "-e", "STDOUT.sync=true; puts 'ready'; sleep 30"])
      result = nil
      thread = Thread.new { result = shell.run_interactive(command, input: reader, sink: sink) }
      wait_until(timeout: 3) { sink.output.include?("ready") }
      writer.write("\x1a")
      writer.flush
      assert thread.join(3), "foreground job did not stop"
      assert_equal 128 + Signal.list.fetch("TSTP"), result.exit_status
      assert_includes shell.run_for_agent("jobs -s").output, "Stopped"
      thread = Thread.new { result = shell.run_interactive("fg", input: reader, sink: sink) }
      # Allow the resumed foreground group to acquire the PTY before Ctrl-C.
      sleep 0.05
      writer.write("\x03")
      writer.flush
      assert thread.join(3), "foreground job did not respond to interrupt"
      assert_equal 130, result.exit_status
      assert_equal 0, shell.run_for_agent(":").exit_status
    ensure
      shell&.close
      thread&.join(1)
      reader&.close
      writer&.close
    end
  end

  def test_exec_reports_final_state_and_closes_the_hosted_shell
    Dir.mktmpdir("persistent-exec") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent("exec printf replaced; printf bad")
      assert_equal 0, result.exit_status
      assert_equal "$ exec printf replaced; printf bad\nreplaced\n", result.output
      assert shell.exited?
    ensure
      shell&.close
    end
  end

  def test_hosted_exec_interprets_executable_text_and_closes_the_session
    Dir.mktmpdir("persistent-exec-text") do |dir|
      File.write(File.join(dir, "native-text"), "printf '%s' \"$((5 + 2) )\"; exit 7")
      File.chmod(0o700, File.join(dir, "native-text"))
      shell = build_shell(dir)
      result = shell.run_for_agent("exec ./native-text; printf bad")
      assert_equal 7, result.exit_status
      assert_equal "$ exec ./native-text; printf bad\n7\nExit status: 7\n", result.output
      assert shell.exited?
    ensure
      shell&.close
    end
  end

  def test_hosted_executable_text_keeps_background_descendants_in_the_owned_group
    Dir.mktmpdir("persistent-text-jobs") do |dir|
      File.write(File.join(dir, "native-text"), %q{sleep 30 & printf '%s' "$!" >nested.pid; exec /usr/bin/true})
      File.chmod(0o700, File.join(dir, "native-text"))
      shell = build_shell(dir)
      result = shell.run_for_agent(%q{./native-text & printf '%s' "$!"})
      assert_equal 0, result.exit_status
      group = Integer(result.output.lines.last.strip)
      wait_until(timeout: 3) { File.exist?(File.join(dir, "nested.pid")) && !File.zero?(File.join(dir, "nested.pid")) }
      nested = Integer(File.read(File.join(dir, "nested.pid")))
      assert_equal group, Process.getpgid(nested)
      assert_includes shell.run_for_agent("jobs -r").output, "Running"
      shell.close
      wait_until(timeout: 2) do
        Process.kill(0, -group)
        false
      rescue Errno::ESRCH
        true
      end
      assert_raises(Errno::ESRCH) { Process.kill(0, -group) }
    ensure
      shell&.close
      begin
        Process.kill("KILL", -group) if group
      rescue Errno::ESRCH
        # Normal shutdown already removed the entire group.
      end
    end
  end

  def test_native_aliases_are_not_preexpanded_by_the_prompt_router
    Dir.mktmpdir("persistent-aliases") do |dir|
      shell = build_shell(dir)
      assert_equal 0, shell.run_for_agent("alias printf='printf prefix:%s'").exit_status
      result = shell.run_for_agent("printf value")
      assert_equal "$ printf value\nprefix:value\n", result.output
      result = shell.run_for_agent(%q{"printf" '%s' literal})
      assert_equal "$ \"printf\" '%s' literal\nliteral\n", result.output
      assert_equal 0, shell.run_for_agent("alias choose='if'").exit_status
      result = shell.run_for_agent("choose true; then command printf yes; fi")
      assert_equal 0, result.exit_status
      assert_includes result.output, "yes"
    ensure
      shell&.close
    end
  end

  def test_dot_sources_native_code_while_source_remains_declarative
    Dir.mktmpdir("persistent-source") do |dir|
      File.write(File.join(dir, "library.kwsh"), "export NATIVE_LIBRARY=ready\nprintf sourced\n")
      shell = build_shell(dir)
      result = shell.run_for_agent(". ./library.kwsh")
      assert_equal 0, result.exit_status
      assert_includes result.output, "sourced"
      assert_equal "ready", shell.child_env["NATIVE_LIBRARY"]
    ensure
      shell&.close
    end
  end

  def test_signal_traps_remain_active_while_the_hosted_shell_is_idle
    Dir.mktmpdir("persistent-traps") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent(%q{trap 'printf caught >notification' USR1; printf '%s' "$$"})
      pid = Integer(result.output.lines.last.strip)
      Process.kill("USR1", pid)
      path = File.join(dir, "notification")
      wait_until(timeout: 2) { File.exist?(path) && File.read(path) == "caught" }
      assert_equal "caught", File.read(path)
      assert_equal 0, shell.run_for_agent(":").exit_status
    ensure
      shell&.close
    end
  end

  def test_chld_traps_do_not_retrigger_themselves_while_idle
    Dir.mktmpdir("persistent-traps") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent(%q{trap 'printf x >>notifications' CHLD; /usr/bin/true})
      assert_equal 0, result.exit_status
      path = File.join(dir, "notifications")
      wait_until(timeout: 2) { File.exist?(path) && File.size(path).positive? }
      initial = File.read(path)
      sleep 0.15
      assert_equal initial, File.read(path)
    ensure
      shell&.close
    end
  end

  def test_foreground_terminal_ownership_survives_stdin_redirection
    Dir.mktmpdir("persistent-terminal") do |dir|
      shell = build_shell(dir)
      reader, writer = IO.pipe
      sink = Sink.new
      code = "STDOUT.sync=true; puts 'ready'; File.open('/dev/tty') { |tty| print 'got=' + tty.gets }"
      command = Shellwords.join([RbConfig.ruby, "-e", code]) + " </dev/null"
      result = nil
      thread = Thread.new { result = shell.run_interactive(command, input: reader, sink: sink) }
      wait_until(timeout: 3) { sink.output.include?("ready") }
      writer.write("answer\n")
      writer.flush
      assert thread.join(3), "redirected foreground command could not read its terminal"
      assert_equal 0, result.exit_status
      assert_includes sink.output, "got=answer"
      assert_equal 0, shell.run_for_agent(":").exit_status
    ensure
      shell&.close
      thread&.join(1)
      reader&.close
      writer&.close
    end
  end

  def test_stopped_jobs_save_and_restore_terminal_modes
    Dir.mktmpdir("persistent-modes") do |dir|
      shell = build_shell(dir)
      # PENDIN is a transient kernel flag after switching back to canonical mode.
      modes = -> { shell.run_for_agent("stty -a").output.gsub(/-?pendin\b/, "").split.join(" ") }
      baseline = modes.call
      code = <<~'RUBY'
        require 'io/console'
        STDOUT.sync = true
        original = STDIN.console_mode
        STDIN.raw!
        Process.kill('TSTP', Process.pid)
        puts "echo=#{STDIN.echo?}"
        STDIN.console_mode = original
      RUBY
      File.write(File.join(dir, "pager.kwsh"), Shellwords.join([RbConfig.ruby, "-e", code]))
      result = shell.run_for_agent("kwsh ./pager.kwsh")
      assert_equal 128 + Signal.list.fetch("TSTP"), result.exit_status
      assert_equal baseline, modes.call
      result = shell.run_for_agent("fg")
      assert_equal 0, result.exit_status
      assert_includes result.output, "echo=false"
      assert_equal baseline, modes.call
    ensure
      shell&.close
    end
  end

  def test_hosted_exec_keeps_nested_background_descendants_owned
    Dir.mktmpdir("persistent-owned-exec") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent(%q{{ sleep 30 & printf '%s' "$!" >nested.pid; exec /usr/bin/true; } & printf '%s' "$!"})
      assert_equal 0, result.exit_status
      group = Integer(result.output.lines.last.strip)
      wait_until(timeout: 2) { File.exist?(File.join(dir, "nested.pid")) }
      sleep 0.05
      assert_includes shell.run_for_agent("jobs -r").output, "Running"
      shell.close
      wait_until(timeout: 2) do
        Process.kill(0, -group)
        false
      rescue Errno::ESRCH
        true
      end
      assert_raises(Errno::ESRCH) { Process.kill(0, -group) }
    ensure
      shell&.close
      begin
        Process.kill("KILL", -group) if group
      rescue Errno::ESRCH
        # The assertion above normally confirms that the whole group is gone.
      end
    end
  end

  def test_commands_share_directory_and_environment_state
    Dir.mktmpdir("persistent-shell") do |dir|
      nested = File.join(dir, "nested")
      Dir.mkdir(nested)
      shell = build_shell(dir)

      shell.run("cd nested")
      shell.run("export KWARD_PERSISTENT_SHELL=ready")
      result = shell.run_for_agent("printf '%s:%s' \"$PWD\" \"$KWARD_PERSISTENT_SHELL\"")

      assert_equal nested, shell.cwd
      assert_includes result.output, "#{nested}:ready"
    ensure
      shell&.close
    end
  end

  def test_interactive_commands_use_the_same_persistent_process
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir)
      pending = shell.run("printf interactive")
      sink = Sink.new

      result = shell.run_interactive(pending.interactive_command, input: nil, sink: sink)
      shell.record_interactive_result(output: sink.output, exit_status: result.exit_status)

      assert_equal 0, result.exit_status
      assert_equal "interactive", sink.output
      assert_equal "interactive", shell.context_snapshot[:last_output]
    ensure
      shell&.close
    end
  end

  def test_tab_action_detaches_interactive_command_without_interrupting_shell
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir)
      input_reader, input_writer = IO.pipe
      sink = Sink.new
      detached_sink = Kward::BufferedPtyOutputSink.new(max_capture_bytes: 10_000)
      input_writer.write("\e[50;5u")
      input_writer.flush

      result = shell.run_interactive(
        "sleep 0.2; printf done",
        input: input_reader,
        sink: sink,
        tab_action_handler: ->(_chunk) { { input: "", tab_action: { tab_action: :select, index: 1 } } },
        on_detach: -> { detached_sink }
      )

      assert_equal({ tab_action: :select, index: 1 }, result.tab_action)
      assert result.background
      wait_until(timeout: 2) { result.background.complete? }
      completed = result.background.result
      assert_equal 0, completed.exit_status
      assert_includes detached_sink.captured_output, "done"
      assert_equal 0, shell.run_for_agent(":").exit_status
    ensure
      input_reader&.close unless input_reader&.closed?
      input_writer&.close unless input_writer&.closed?
      shell&.close
    end
  end

  def test_interactive_commands_forward_single_keys_while_input_is_raw
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir)
      input_reader, input_writer = IO.pipe
      sink = Sink.new
      result = nil
      input_reader.define_singleton_method(:raw) do |&block|
        instance_variable_set(:@raw_started, true)
        block.call
      end

      worker = Thread.new do
        result = shell.run_interactive(
          "#{Shellwords.escape(RbConfig.ruby)} -rio/console -e 'STDIN.raw { STDOUT.write(\"ready\"); STDOUT.flush; STDOUT.write(STDIN.read(1)) }'",
          input: input_reader,
          sink: sink
        )
      end
      wait_until(timeout: 1, message: "persistent shell input did not enter raw mode") do
        input_reader.instance_variable_get(:@raw_started)
      end
      wait_until(timeout: 1, message: "interactive command did not become ready") do
        sink.output.include?("ready")
      end
      input_writer.write("q")
      input_writer.flush
      worker.join(2)

      refute worker.alive?, "expected the single key to reach the interactive command"
      assert_equal 0, result.exit_status
      assert result.input_forwarded
      assert_equal "readyq", sink.output
    ensure
      worker&.kill if worker&.alive?
      input_reader&.close unless input_reader&.closed?
      input_writer&.close unless input_writer&.closed?
      shell&.close
    end
  end

  def test_interactive_commands_do_not_inherit_a_kward_git_pager
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir, env: { "PATH" => ENV.fetch("PATH", "") })
      sink = Sink.new

      result = shell.run_interactive("#{Shellwords.escape(RbConfig.ruby)} -e 'print ENV.fetch(\"GIT_PAGER\", \"unset\")'", input: nil, sink: sink)

      assert_equal 0, result.exit_status
      assert_equal "unset", sink.output
    ensure
      shell&.close
    end
  end

  def test_noninteractive_commands_suppress_and_restore_the_git_pager
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(
        dir,
        env: { "PATH" => ENV.fetch("PATH", ""), "GIT_PAGER" => "less" }
      )

      agent_result = shell.run_for_agent("printf '%s' \"$GIT_PAGER\"")
      capture_result = shell.run("capture printf '%s' \"$GIT_PAGER\"")
      sink = Sink.new
      interactive_result = shell.run_interactive("printf '%s' \"$GIT_PAGER\"", input: nil, sink: sink)

      assert_equal 0, agent_result.exit_status
      assert_includes agent_result.output, "cat"
      assert_equal 0, capture_result.exit_status
      assert_includes capture_result.output, "cat"
      assert_equal 0, interactive_result.exit_status
      assert_equal "less", sink.output
    ensure
      shell&.close
    end
  end

  def test_agent_commands_are_noninteractive_but_use_the_persistent_process
    Dir.mktmpdir("persistent-shell") do |dir|
      nested = File.join(dir, "nested")
      Dir.mkdir(nested)
      shell = build_shell(dir)

      shell.run_for_agent("cd nested")
      result = shell.run_for_agent("pwd")

      assert_equal nested, shell.cwd
      assert_includes result.output, nested
    ensure
      shell&.close
    end
  end

  def test_source_updates_aliases_and_environment_in_the_persistent_process
    Dir.mktmpdir("persistent-shell") do |dir|
      File.write(File.join(dir, "aliases.kwshrc"), <<~KWSHRC)
        export KWARD_PERSISTENT_SOURCE=ready
        alias sourced='printf sourced'
        printf unexpected >should-not-exist
      KWSHRC
      shell = build_shell(dir)

      result = shell.run("source aliases.kwshrc")
      alias_result = shell.run_for_agent("sourced")
      environment_result = shell.run_for_agent("printf %s \"$KWARD_PERSISTENT_SOURCE\"")

      assert_equal 0, result.exit_status
      assert_equal 0, alias_result.exit_status
      assert_includes alias_result.output, "sourced"
      assert_includes environment_result.output, "ready"
      refute File.exist?(File.join(dir, "should-not-exist"))
    ensure
      shell&.close
    end
  end

  def test_source_reports_invalid_configuration_errors
    Dir.mktmpdir("native-shell") do |dir|
      File.write(File.join(dir, "invalid.kwshrc"), "export INVALID='contains\0nul'\n")
      shell = build_shell(dir)
      result = shell.run("source invalid.kwshrc")
      refute_equal 0, result.exit_status
      assert_includes result.output, "kwsh: source:"
      assert_includes result.output, "invalid.kwshrc:1: Unmatched quote"
    ensure
      shell&.close
    end
  end

  def test_source_accepts_custom_ifs_without_executing_configuration
    Dir.mktmpdir("native-shell") do |dir|
      File.write(File.join(dir, "ifs.kwshrc"), "export IFS=:\nprintf bad >sentinel\n")
      shell = build_shell(dir)
      assert_equal 0, shell.run("source ifs.kwshrc").exit_status
      result = shell.run_for_agent('value=a:b; printf "<%s>" $value')
      assert_equal 0, result.exit_status
      assert_includes result.output, "<a><b>"
      assert_equal ":", shell.child_env["IFS"]
      refute File.exist?(File.join(dir, "sentinel"))
    ensure
      shell&.close
    end
  end

  def test_shell_agent_runs_parameter_case_and_read_workflow_natively
    Dir.mktmpdir("native-shell") do |dir|
      File.write(File.join(dir, "input"), "one.rb\ntwo.txt\nlast.rb")
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/must-not-be-launched")
      tool = Kward::Tools::RunShellCommand.new(shell_prompt_session: Kward::ShellPromptSession.new(shell))
      source = <<~'SHELL'
        count=0
        while IFS= read -r file || [ -n "$file" ]; do
          case "$file" in *.rb) count=$((count + 1));; esac
        done < input
        export RESULT=${count:-0}
        printf 'count=%s' "$RESULT"
      SHELL
      output = tool.call({ "command" => source }, nil)
      assert_includes output, "Exit status: 0"
      assert_includes output, "count=2"
      assert_equal "2", shell.child_env["RESULT"]
      assert_includes shell.run_for_agent('printf "%s" "$count"').output, "2"
      assert_nil shell.compose_input("case x in")
      assert_nil shell.compose_input("x) printf matched;;")
      command = shell.compose_input("esac")
      assert_includes shell.run_for_agent(command).output, "matched"
    ensure
      shell&.close
    end
  end

  def test_shell_agent_tool_accepts_the_exact_spaced_arithmetic_command
    Dir.mktmpdir("native-shell") do |dir|
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/must-not-be-launched")
      shell.run_for_agent("echo 5")
      session = Kward::ShellPromptSession.new(shell)
      tool = Kward::Tools::RunShellCommand.new(shell_prompt_session: session)

      output = tool.call({ "command" => "echo $((5 + 2) )" }, nil)

      assert_includes output, "Exit status: 0"
      assert_includes output, "$ echo $((5 + 2) )\n7\n"
      assert_equal "echo $((5 + 2) )", shell.context_snapshot[:last_command]
      assert_equal 0, shell.context_snapshot[:exit_status]
    ensure
      shell&.close
    end
  end

  def test_native_arithmetic_works_for_the_shell_agent_and_keeps_state
    Dir.mktmpdir("native-shell") do |dir|
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/must-not-be-launched")
      shell.run_for_agent("echo 5")
      session = Kward::ShellPromptSession.new(shell)
      output = session.run("echo $((5 + 2))")
      assert_includes output, "Exit status: 0"
      assert_includes output, "\n7\n"

      shell.run_for_agent("value=5")
      result = shell.run_for_agent('value=$((value + 2)); echo "$value"')
      assert_equal 0, result.exit_status
      assert_includes result.output, "\n7\n"
      assert_nil shell.compose_input('echo $((value +')
      source = shell.compose_input('2))')
      assert_includes shell.run_for_agent(source).output, "\n9\n"

      failure = shell.run_for_agent('echo $((value / 0))')
      assert_equal 2, failure.exit_status
      assert_includes failure.output, "division by zero"
      assert_includes shell.run_for_agent('echo "$value"').output, "\n7\n"
    ensure
      shell&.close
    end
  end

  def test_native_programs_share_functions_and_authoritative_exported_state
    Dir.mktmpdir("native-shell") do |dir|
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/must-not-be-launched")
      definition = shell.run_for_agent('prepare() { local_value="one two"; export RESULT="$local_value"; }; prepare')
      result = shell.run_for_agent('for word in "$RESULT"; do printf "<%s>" "$word"; done')

      assert_equal 0, definition.exit_status
      assert_equal 0, result.exit_status
      assert_includes result.output, "<one two>"
      assert_equal "one two", shell.child_env["RESULT"]
      refute shell.child_env.key?("local_value")
    ensure
      shell&.close
    end
  end

  def test_unsupported_syntax_fails_before_running_any_command
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent('printf touched >sentinel; printf x & &')

      assert_equal 2, result.exit_status
      assert_includes result.output, "expected command"
      refute File.exist?(File.join(dir, "sentinel"))
      follow_up = shell.run_for_agent('printf "status=%s" "$?"')
      assert_includes follow_up.output, "status=2"
    ensure
      shell&.close
    end
  end

  def test_multiline_composition_waits_for_a_complete_program
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir)
      assert_nil shell.compose_input("if true; then")
      assert_equal "Shell ... >", shell.input_prompt_label
      assert_nil shell.compose_input("printf complete")
      source = shell.compose_input("fi")
      assert_equal "if true; then\nprintf complete\nfi", source
      assert_equal shell.prompt_label, shell.input_prompt_label
      assert_equal 0, shell.run_for_agent(source).exit_status
      assert_equal "? explain this", shell.compose_input("? explain this")
    ensure
      shell&.close
    end
  end

  def test_cli_collects_multiline_programs_and_preserves_them_across_tab_actions
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir)
      tab_action = { tab_action: :next }
      answers = ["if true; then", tab_action, "printf complete", "fi"]
      labels = []
      prompt = Object.new
      prompt.define_singleton_method(:ask) { |label| labels << label; answers.shift }
      cli = Kward::CLI.allocate
      cli.instance_variable_set(:@prompt, prompt)

      assert_equal tab_action, cli.send(:ask_kwsh, shell)
      assert_equal "if true; then\nprintf complete\nfi", cli.send(:ask_kwsh, shell)
      assert_equal [shell.prompt_label, "Shell ... >", "Shell ... >", "Shell ... >"], labels
    ensure
      shell&.close
    end
  end

  def test_private_control_state_does_not_enter_terminal_output
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir, configured_env: { "KWARD_NATIVE_TEST_SECRET" => "private-control-value" })
      result = shell.run_for_agent(":")
      refute_includes result.output, "private-control-value"
      assert_equal "private-control-value", shell.child_env["KWARD_NATIVE_TEST_SECRET"]
    ensure
      shell&.close
    end
  end

  def test_timeout_interrupts_native_loops_without_losing_variables
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir, timeout_seconds: 1)
      result = shell.run_for_agent('KEPT=yes; while true; do :; done')
      follow_up = shell.run_for_agent('printf "%s" "$KEPT"')

      assert_equal 1, result.exit_status
      assert_includes result.output, "timed out"
      assert_equal 0, follow_up.exit_status
      assert_includes follow_up.output, "yes"
    ensure
      shell&.close
    end
  end

  def test_nested_native_substitutions_can_be_cancelled_without_losing_the_session
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir, timeout_seconds: 1)
      result = shell.run_for_agent('KEPT=yes; value=$(while true; do :; done)')
      assert_equal 1, result.exit_status
      assert_includes result.output, "timed out"
      follow_up = shell.run_for_agent('printf "%s" "$KEPT"')
      assert_equal 0, follow_up.exit_status
      assert_includes follow_up.output, "yes"
    ensure
      shell&.close
    end
  end

  def test_native_extensions_work_through_the_shell_agent_without_a_system_shell
    Dir.mktmpdir("native-shell") do |dir|
      shell = Kward::PersistentShellSession.new(cwd: dir, shell: "/must-not-be-launched")
      tool = Kward::Tools::RunShellCommand.new(shell_prompt_session: Kward::ShellPromptSession.new(shell))
      source = <<~'SHELL'
        values=(one "two words")
        for ((i=0; i<2; i++)); do
          [[ ${values[i]} == *o* ]] && printf '<%s>' "${values[i]}"
        done
        cat <(printf ':native')
        printf ':done' > >(cat)
      SHELL
      result = tool.call({ "command" => source }, nil)
      assert_includes result, "Exit status: 0"
      assert_includes result, "<one><two words>:native:done"
      assert_equal 0, shell.run_for_agent(":").exit_status
      assert_nil shell.compose_input("cat <<EOF")
      assert_nil shell.compose_input("hello")
      assert_includes shell.run_for_agent(shell.compose_input("EOF")).output, "hello"
    ensure
      shell&.close
    end
  end

  def test_exit_inside_a_compound_program_is_reported_to_the_host
    Dir.mktmpdir("native-shell") do |dir|
      shell = build_shell(dir)
      result = shell.run_for_agent('if true; then exit 7; fi')
      assert_equal 7, result.exit_status
      assert result.exit_shell
      assert shell.exited?
    ensure
      shell&.close
    end
  end

  def test_output_limit_is_bounded_without_losing_the_shell
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir, max_output_bytes: 4)

      result = shell.run_for_agent("printf 123456")
      follow_up = shell.run_for_agent(":")

      assert_equal 1, result.exit_status
      assert_includes result.output, "1234"
      assert_includes result.output, "output exceeded 4 bytes"
      assert_equal 0, follow_up.exit_status
    ensure
      shell&.close
    end
  end

  def test_cancellation_interrupts_agent_command_and_keeps_shell_available
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir)
      cancellation = Kward::Cancellation.new
      result = nil
      worker = Thread.new do
        result = shell.run_for_agent("sleep 5", cancellation: cancellation)
      end

      sleep 0.1
      cancellation.cancel!
      worker.join(2)
      follow_up = shell.run_for_agent("pwd")

      refute worker.alive?
      assert_equal 130, result.exit_status
      assert_equal 0, follow_up.exit_status
    ensure
      worker&.kill if worker&.alive?
      shell&.close
    end
  end

  def test_restarted_worker_sets_size_on_its_new_pty
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir, window_size_provider: -> { [37, 94] })
      assert_equal "37 94", shell.run_for_agent("stty size").output.lines.last.strip

      shell.send(:restart_process)

      assert_equal "37 94", shell.run_for_agent("stty size").output.lines.last.strip
    ensure
      shell&.close
    end
  end

  def test_timeout_keeps_the_shell_available
    Dir.mktmpdir("persistent-shell") do |dir|
      shell = build_shell(dir, timeout_seconds: 1)

      result = shell.run_for_agent("sleep 5")
      follow_up = shell.run_for_agent("pwd")

      assert_equal 1, result.exit_status
      assert_includes result.output, "command timed out after 1 seconds"
      assert_equal 0, follow_up.exit_status
      assert_includes follow_up.output, dir
    ensure
      shell&.close
    end
  end
end
