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
