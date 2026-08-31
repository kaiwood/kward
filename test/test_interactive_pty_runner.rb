require "pty"
require_relative "test_helper"
require_relative "../lib/kward/pty/interactive_runner"

class TestInteractivePtyRunner < KwardTestCase
  class RecordingSink
    attr_reader :chunks, :input_forwarded_count
    attr_reader :finished

    def initialize(output)
      @output = output
      @chunks = []
      @input_forwarded_count = 0
      @finished = false
    end

    def write(chunk)
      @chunks << chunk
      @output.write(chunk)
    end

    def flush
      @output.flush
    end

    def input_forwarded
      @input_forwarded_count += 1
    end

    def finish
      @finished = true
      flush
    end
  end

  def test_forwards_input_to_child_and_delivers_output_chunks_to_sink
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    sink = RecordingSink.new(output_writer)
    runner = Kward::InteractivePtyRunner.new
    result = nil
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
        sink: sink
      )
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
    assert_operator sink.input_forwarded_count, :>=, 1
    assert sink.finished
    assert_equal output, sink.chunks.join
    assert_includes output, "q"
  ensure
    worker&.kill if worker&.alive?
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_initial_buffered_input_is_reported_before_child_output
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    sink = RecordingSink.new(output_writer)
    input_writer.write("q")
    input_writer.close

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-rio/console",
      "-e",
      "STDIN.raw { print STDIN.getc; STDOUT.flush }",
      input: input_reader,
      sink: sink
    )
    output_writer.close

    assert result.input_forwarded
    assert_operator sink.input_forwarded_count, :>=, 1
    assert sink.finished
    assert_includes output_reader.read, "q"
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_forwards_terminal_control_output_byte_for_byte_in_sink_order
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    payload = "\e[1;1Hchild output\e[?1049hfull screen\e[?1049l"
    sink = RecordingSink.new(output_writer)

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "STDOUT.write(#{payload.inspect})",
      input: input_reader,
      sink: sink
    )
    output_writer.close

    assert_equal 0, result.exit_status
    assert_equal payload, output_reader.read
    assert_equal payload, sink.chunks.join
  ensure
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
      sink: Kward::PassthroughPtyOutputSink.new(output: output_writer)
    )
    output_writer.close

    assert_equal 0, result.exit_status
    assert_equal expected, output_reader.read
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_bounded_capture_does_not_interrupt_passthrough
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    payload = "#{"x" * 31}\e[?1049h#{"y" * 10_000}-suffix"
    sink = Kward::PassthroughPtyOutputSink.new(output: output_writer, max_capture_bytes: 32)

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "STDOUT.write(#{payload.inspect})",
      input: input_reader,
      sink: sink
    )
    output_writer.close

    assert_equal 0, result.exit_status
    assert_equal payload, output_reader.read
    assert_equal payload.byteslice(0, 32), sink.captured_output
    assert sink.truncated?
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
      sink: Kward::PassthroughPtyOutputSink.new(output: output_writer)
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
      sink: Kward::PassthroughPtyOutputSink.new(output: output_writer)
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
      sink: Kward::PassthroughPtyOutputSink.new(output: output_writer)
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
      sink: Kward::PassthroughPtyOutputSink.new(output: output_writer)
    )

    refute_equal 0, result.exit_status
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_tab_action_handler_stops_child_without_forwarding_tab_key
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    sink = RecordingSink.new(output_writer)
    input_writer.write("\e[50;5u")
    input_writer.flush
    seen = []

    result = Kward::InteractivePtyRunner.new.run(
      RbConfig.ruby,
      "-e",
      "sleep 10",
      input: input_reader,
      sink: sink,
      tab_action_handler: lambda do |chunk|
        seen << chunk
        { input: "", tab_action: { tab_action: :select, index: 1 } }
      end
    )

    assert_equal({ tab_action: :select, index: 1 }, result.tab_action)
    refute result.input_forwarded
    assert_equal ["\e[50;5u"], seen
  ensure
    close_ios(input_reader, input_writer, output_reader, output_writer)
  end

  def test_tab_action_detaches_child_when_detach_handler_is_available
    Dir.mktmpdir("interactive-pty") do |dir|
      completed_path = File.join(dir, "completed")
      input_reader, input_writer = IO.pipe
      sink = RecordingSink.new(StringIO.new)
      detached_sink = Kward::BufferedPtyOutputSink.new(max_capture_bytes: 10_000)
      input_writer.write("\e[50;5u")
      input_writer.flush

      result = Kward::InteractivePtyRunner.new.run(
        RbConfig.ruby,
        "-e",
        "sleep 0.2; print 'output'; File.write(ARGV.fetch(0), 'done')",
        completed_path,
        input: input_reader,
        sink: sink,
        tab_action_handler: ->(_chunk) { { input: "", tab_action: { tab_action: :select, index: 1 } } },
        on_detach: -> { detached_sink }
      )

      assert_equal({ tab_action: :select, index: 1 }, result.tab_action)
      assert result.background
      refute result.background.complete?
      wait_until(timeout: 2) { result.background.complete? }
      assert_equal 0, result.background.result.exit_status
      assert_equal "done", File.read(completed_path)
      assert_equal "output", detached_sink.captured_output
    ensure
      close_ios(input_reader, input_writer)
    end
  end

  def test_terminates_and_reaps_child_when_sink_write_fails
    Dir.mktmpdir("interactive-pty") do |dir|
      pid_path = File.join(dir, "pid")
      input_reader, input_writer = IO.pipe
      sink = Object.new
      sink.define_singleton_method(:write) { |_chunk| raise IOError, "output failed" }

      error = assert_raises(IOError) do
        Kward::InteractivePtyRunner.new.run(
          RbConfig.ruby,
          "-e",
          "File.write(#{pid_path.inspect}, Process.pid.to_s); puts 'ready'; STDOUT.flush; sleep 10",
          input: input_reader,
          sink: sink
        )
      end
      pid = File.read(pid_path).to_i

      assert_equal "output failed", error.message
      wait_until(timeout: 1, message: "interactive PTY child was not terminated") { !process_running?(pid) }
      assert_raises(Errno::ECHILD) { Process.wait(pid, Process::WNOHANG) }
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
