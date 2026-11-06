require_relative "test_helper"
require "open3"
require "timeout"
require "shellwords"

class TestNativeShellSignals < KwardTestCase
  EXECUTABLE = File.expand_path("../exe/kwsh", __dir__)

  def invoke(source, interactive: false, ignored: [])
    launcher = 'ARGV.shift.split(",").each { |name| Signal.trap(name, "IGNORE") }; exec(*ARGV)'
    command = [RbConfig.ruby, "-e", launcher, ignored.join(","), RbConfig.ruby, EXECUTABLE, interactive ? "-ic" : "-c", source]
    Open3.popen3({ "ENV" => nil, "LC_ALL" => "C" }, *command, pgroup: true) do |input, output, error, waiter|
      input.close
      readers = [output, error].map { |io| Thread.new { io.read } }
      begin
        Timeout.timeout(5) do
          status = waiter.value
          [readers[0].value, readers[1].value, status]
        end
      ensure
        kill_process(-waiter.pid)
        waiter.join(2)
        readers.each { |thread| thread.join(2) }
      end
    end
  end

  def test_interactive_default_signals_are_ignored
    output, error, status = invoke("kill -TERM $$; kill -QUIT $$; kill -TTIN $$; kill -TTOU $$; kill -TSTP $$; printf alive", interactive: true)
    assert status.success?, error
    assert_equal "alive", output
  end

  def test_inherited_ignored_signals_cannot_be_reset_or_caught_noninteractively
    output, error, status = invoke(<<~'SHELL', ignored: ["USR1"])
      trap
      trap 'printf bad' USR1
      kill -USR1 $$
      trap - USR1
      kill -USR1 $$
      trap -p USR1
      printf alive
    SHELL
    assert status.success?, error
    assert_empty error
    assert_equal "trap -- '' USR1\ntrap -- '' USR1\nalive", output
  end

  def test_interactive_shell_can_override_an_inherited_ignore
    output, error, status = invoke("trap 'printf caught' USR1; kill -USR1 $$; printf done", ignored: ["USR1"], interactive: true)
    assert status.success?, error
    assert_equal "caughtdone", output
  end

  def test_trap_p_includes_defaults_and_round_trips_all_conditions
    output, error, status = invoke(<<~'SHELL')
      trap 'printf caught' USR1
      saved=$(trap -p)
      trap 'printf wrong' USR2
      eval "$saved"
      trap -p USR1 USR2 INT EXIT
      kill -USR1 $$
    SHELL
    assert status.success?, error
    assert_empty error
    lines = output.lines
    assert_equal ["trap", "--", "printf caught", "USR1"], Shellwords.split(lines[0])
    assert_equal "trap -- - USR2\ntrap -- - INT\ntrap -- - EXIT\ncaught", lines.drop(1).join
  end

  def test_trap_p_lists_every_platform_condition_except_uncatchable_signals
    output, error, status = invoke("trap -p")
    assert status.success?, error
    names = output.lines.map { |line| Shellwords.split(line).last }
    expected = Signal.list.reject { |name, _| %w[KILL STOP].include?(name) }.values.uniq
    assert_equal expected.sort, names.map { |name| Signal.list.fetch(name) }.sort
  end

  def test_subshell_inspection_survives_until_a_trap_mutation
    output, error, status = invoke(<<~'SHELL')
      trap 'printf parent' USR1
      (trap; trap - USR1; trap -p USR1)
      printf '%s\n' "$(trap)"
      trap -p USR1
    SHELL
    assert status.success?, error
    assert_empty error
    lines = output.lines.map { |line| Shellwords.split(line) }
    action = ["trap", "--", "printf parent", "USR1"]
    assert_equal [action, ["trap", "--", "-", "USR1"], action, action], lines
  end

  def test_subshell_resets_caught_actions_but_not_inherited_ignored_int
    probe = Shellwords.join([RbConfig.ruby, "-e", 'Process.kill("USR1", Process.ppid)'])
    output, error, status = invoke("trap 'printf wrong' USR1; (#{probe}); printf '%s' \"$?\"")
    assert status.success?, error
    assert_equal (128 + Signal.list.fetch("USR1")).to_s, output
    interrupt = Shellwords.join([RbConfig.ruby, "-e", 'Process.kill("INT", Process.ppid)'])
    output, error, status = invoke("(trap 'printf wrong' INT; #{interrupt}; printf child); printf parent", ignored: ["INT"])
    assert status.success?, error
    assert_equal "childparent", output
  end

  def test_interactive_defaults_do_not_leak_into_children_but_explicit_ignores_do
    probe = Shellwords.join([RbConfig.ruby, "-e", 'print Signal.trap("TERM", "DEFAULT") == "IGNORE" ? "ignored" : "default"'])
    output, error, status = invoke("#{probe}; trap '' TERM; #{probe}", interactive: true)
    assert status.success?, error
    assert_equal "defaultignored", output
    output, error, status = invoke("set +m; { trap - INT QUIT; #{Shellwords.join([RbConfig.ruby, '-e', 'print Signal.trap("INT", "DEFAULT")'])}; } & wait", interactive: true)
    assert status.success?, error
    assert_equal "IGNORE", output
  end

  def test_explicit_default_queries_and_uncatchable_resets_round_trip
    output, error, status = invoke(%q{saved=$(trap -p -- INT QUIT KILL STOP); eval "$saved"; printf '%s\n' "$saved"})
    assert status.success?, error
    assert_empty error
    assert_equal "trap -- - INT\ntrap -- - QUIT\ntrap -- - KILL\ntrap -- - STOP\n", output
  end

  def test_nested_subshells_preserve_inspection_without_executing_parent_exit_traps
    output, error, status = invoke(%q{trap 'printf parent-exit' EXIT; ( (trap) ); printf '%s\n' "$(trap -p EXIT)"})
    assert status.success?, error
    assert_empty error
    lines = output.lines
    assert_equal ["trap", "--", "printf parent-exit", "EXIT"], Shellwords.split(lines[0])
    assert_equal lines[0], lines[1]
    assert_equal "parent-exit", lines[2]
  end

  def test_exec_and_native_scripts_restore_child_defaults
    probe = Shellwords.join([RbConfig.ruby, "-e", 'print Signal.trap("TERM", "DEFAULT") == "IGNORE" ? "ignored" : "default"'])
    ["set +m; #{probe}", "exec #{probe}"].each do |source|
      output, error, status = invoke(source, interactive: true)
      assert status.success?, error
      assert_equal "default", output
    end
    Dir.mktmpdir("native-signal-script") do |dir|
      file = File.join(dir, "script")
      File.write(file, "trap -p TERM; kill -TERM $$; printf wrong\n")
      File.chmod(0o700, file)
      ["kwsh #{Shellwords.escape(file)}", Shellwords.escape(file)].each do |command|
        output, error, status = invoke("#{command}; printf '%s' \"$?\"", interactive: true)
        assert status.success?, error
        assert_equal "trap -- - TERM\n#{128 + Signal.list.fetch('TERM')}", output
      end
    end
  end

  def test_foreground_traps_are_deferred_and_exit_traps_keep_status
    probe = Shellwords.join([RbConfig.ruby, "-e", 'Process.kill("USR1", Process.ppid); print "child:"; exit 7'])
    output, error, status = invoke("trap 'printf \"trap:%s:\" \"$?\"' USR1; trap 'printf \"exit:%s\" \"$?\"' EXIT; #{probe}")
    assert_equal 7, status.exitstatus, error
    assert_equal "child:trap:7:exit:7", output
  end

  def test_interrupted_wait_runs_its_trap_before_errexit
    output, error, status = invoke(%q{set -e; trap 'printf "signal:%s" "$?"; wait "$!"' USR1; { sleep 0.1; kill -USR1 $$; sleep 0.1; } & wait "$!"; printf wrong})
    expected = 128 + Signal.list.fetch("USR1")
    assert_equal expected, status.exitstatus, error
    assert_equal "signal:#{expected}", output
  end

  def with_interactive_shell
    Open3.popen3({ "ENV" => nil, "PS1" => "ready> ", "PS2" => "more> " }, RbConfig.ruby, EXECUTABLE, "-i", pgroup: true) do |input, output, error, waiter|
      begin
        Timeout.timeout(5) { yield input, output, error, waiter }
      ensure
        input.close unless input.closed?
        kill_process(-waiter.pid)
        waiter.join(2)
      end
    end
  end

  def kill_process(pid)
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end

  def read_until(io, ending)
    text = +""
    text << io.readpartial(1) until text.end_with?(ending)
    text
  end

  def test_int_discards_unfinished_prompt_input
    with_interactive_shell do |input, output, error, waiter|
      read_until(error, "ready> ")
      input.write("if true; then\n")
      read_until(error, "more> ")
      Process.kill("INT", waiter.pid)
      read_until(error, "ready> ")
      input.write("printf '%s\\n' \"$?\"; exit\n")
      input.close
      assert_equal "130\n", output.read
      assert waiter.value.success?
    end
  end

  def test_int_sent_only_to_the_interactive_shell_does_not_interrupt_a_command
    with_interactive_shell do |input, output, error, waiter|
      read_until(error, "ready> ")
      probe = Shellwords.join([RbConfig.ruby, "-e", 'STDOUT.sync = true; puts "child-ready"; STDIN.read(1)'])
      input.puts(probe)
      assert_equal "child-ready\n", read_until(output, "\n")
      Process.kill("INT", waiter.pid)
      input.write("x")
      read_until(error, "ready> ")
      input.write("printf '%s\\n' \"$?\"; exit\n")
      input.close
      assert_equal "0\n", output.read
      assert waiter.value.success?
    end
  end

  def test_interrupting_the_foreground_command_returns_to_the_prompt
    with_interactive_shell do |input, output, error, waiter|
      read_until(error, "ready> ")
      probe = Shellwords.join([RbConfig.ruby, "-e", 'STDOUT.sync = true; puts Process.pid; STDIN.read(1)'])
      input.puts(probe)
      child = Integer(read_until(output, "\n"))
      Process.kill("INT", child)
      read_until(error, "ready> ")
      child = nil
      input.write("printf '%s\\n' \"$?\"; exit\n")
      input.close
      assert_equal "130\n", output.read
      assert waiter.value.success?
    ensure
      kill_process(child) if child
    end
  end

  def test_hosted_trap_roundtrip_preserves_worker_defaults_and_shutdown_reservation
    probe = <<~RUBY
      require #{File.expand_path("../lib/kward/shell/script_runner", __dir__).inspect}
      handler = proc {}
      Signal.trap("HUP", handler)
      Signal.trap("TSTP", "IGNORE")
      runtime = Kward::NativeShell::Runtime.new(interactive: true, hosted: true)
      error = StringIO.new
      runtime.with_signals do
        status = runtime.run('saved=$(trap -p); eval "$saved"', output: StringIO.new, error: error)
        abort error.string unless status.zero?
        abort "host handler lost" unless Signal.trap("HUP", handler).equal?(handler)
        abort "host stop default lost" unless Signal.trap("TSTP", "IGNORE") == "IGNORE"
        status = runtime.run("trap '' USR2", output: StringIO.new, error: error)
        abort "shutdown signal exposed" unless status == 2 && error.string.include?("reserved for hosted")
      end
      runtime.close
      print "safe"
    RUBY
    output, error, status = invoke(Shellwords.join([RbConfig.ruby, "-e", probe]))
    assert status.success?, error
    assert_empty error
    assert_equal "safe", output
  end

  def test_invalid_trap_condition_does_not_abort_noninteractive_input
    output, error, status = invoke("trap -p NOT_A_SIGNAL; printf '%s' \"$?\"")
    assert status.success?
    assert_includes error, "invalid signal"
    assert_equal "1", output
  end
end
