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

  def test_source_reports_native_configuration_errors
    Dir.mktmpdir("native-shell") do |dir|
      File.write(File.join(dir, "invalid.kwshrc"), "export IFS=:\n")
      shell = build_shell(dir)
      result = shell.run("source invalid.kwshrc")
      refute_equal 0, result.exit_status
      assert_includes result.output, "could not apply configuration"
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
      result = shell.run_for_agent('printf touched >sentinel; printf "$(pwd)"')

      assert_equal 2, result.exit_status
      assert_includes result.output, "not supported"
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
