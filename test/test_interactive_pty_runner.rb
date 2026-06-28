require "pty"
require_relative "test_helper"
require_relative "../lib/kward/interactive_pty_runner"

class TestInteractivePtyRunner < KwardTestCase
  def test_forwards_input_to_child_and_output_to_caller
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
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
        output: output_writer
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
    assert_includes output, "q"
  ensure
    worker&.kill if worker&.alive?
    [input_reader, input_writer, output_reader, output_writer].each do |io|
      io&.close unless io.closed?
    rescue IOError
      nil
    end
  end
end
