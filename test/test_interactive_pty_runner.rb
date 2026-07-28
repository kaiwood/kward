require "pty"
require_relative "test_helper"
require_relative "../lib/kward/interactive_pty_runner"

class TestInteractivePtyRunner < KwardTestCase
  def test_forwards_input_to_child_and_output_to_caller
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    runner = Kward::InteractivePtyRunner.new
    result = nil
    captured_output = +""
    ruby = RbConfig.ruby

    input_reader.define_singleton_method(:raw) do |&block|
      instance_variable_set(:@raw_started, true)
      block.call
    end
    worker = Thread.new do
      result = runner.run(
        ruby,
        "-rio/console",
        "-e",
        "STDIN.raw { print STDIN.getc; STDOUT.flush }",
        input: input_reader,
        output: output_writer
      ) { |chunk| captured_output << chunk }
    end
    wait_until(timeout: 1, message: "interactive PTY runner did not start") { input_reader.instance_variable_get(:@raw_started) }
    input_writer.write("q")
    input_writer.flush
    worker.join(2)
    output_writer.close
    output = output_reader.read

    refute worker.alive?, "expected interactive PTY command to finish"
    assert_equal 0, result.exit_status
    assert result.input_forwarded
    assert_includes output, "q"
    assert_includes captured_output, "q"
  ensure
    worker&.kill if worker&.alive?
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_drains_output_emitted_immediately_before_exit
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    expected = "finished-#{"x" * 16_384}"

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "STDOUT.write(#{expected.inspect})",
      input: input_reader,
      output: output_writer
    )
    output_writer.close

    assert_equal 0, result.exit_status
    assert_equal expected, output_reader.read
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_returns_nonzero_exit_status
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "exit 23",
      input: input_reader,
      output: output_writer
    )

    assert_equal 23, result.exit_status
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_closed_input_does_not_prevent_child_from_finishing
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    input_writer.close

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "print 'done'",
      input: input_reader,
      output: output_writer
    )
    output_writer.close

    assert_equal 0, result.exit_status
    refute result.input_forwarded
    assert_includes output_reader.read, "done"
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_updates_window_size_while_command_runs
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    sizes = [[24, 80], [24, 120]]
    runner = Kward::InteractivePtyRunner.new(window_size_provider: -> { sizes.shift || [24, 120] })

    result = runner.run(
      RbConfig.ruby,
      "-rio/console",
      "-e",
      "sleep 0.08; print IO.console.winsize[1]",
      input: input_reader,
      output: output_writer
    )
    output_writer.close

    assert_equal 0, result.exit_status
    assert_includes output_reader.read, "120"
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_stopped_child_is_terminated_instead_of_stranding_terminal
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "Process.kill('STOP', Process.pid); sleep 10",
      input: input_reader,
      output: output_writer
    )

    refute_equal 0, result.exit_status
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_terminates_child_when_output_forwarding_fails
    Dir.mktmpdir("interactive-pty") do |dir|
      pid_path = File.join(dir, "pid")
      input_reader, input_writer = IO.pipe
      output = Object.new
      output.define_singleton_method(:write) { |_chunk| raise IOError, "output failed" }

      error = assert_raises(IOError) do
        Kward::InteractivePtyRunner.new.run(
          RbConfig.ruby,
          "-e",
          "File.write(#{pid_path.inspect}, Process.pid.to_s); puts 'ready'; STDOUT.flush; sleep 10",
          input: input_reader,
          output: output
        )
      end
      pid = File.read(pid_path).to_i

      assert_equal "output failed", error.message
      wait_until(timeout: 1, message: "interactive PTY child was not terminated") { !process_running?(pid) }
    ensure
      close_ios(input_reader, input_writer)
    end
  end

  private

  def close_ios(*ios)
    ios.compact.each do |io|
      io.close unless io.closed?
    rescue IOError
      nil
    end
  end

  def process_running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
