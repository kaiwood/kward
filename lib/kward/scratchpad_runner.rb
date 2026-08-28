require "open3"
require "rbconfig"
require "tempfile"
require_relative "scratchpad_languages"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Executes scratchpad buffers and returns captured runner output.
  module ScratchpadRunner
    OUTPUT_READ_SIZE = 16 * 1024
    MAX_OUTPUT_BYTES = 1_000_000
    POLL_INTERVAL = 0.05

    Result = Struct.new(:language, :output, :exit_status, :duration, :command, :cancelled, :truncated, keyword_init: true)

    module_function

    def run(language, content, cancelled: nil)
      language = language&.to_sym
      case ScratchpadLanguages.runner(language)
      when :ruby
        run_ruby(content, cancelled: cancelled)
      else
        raise ArgumentError, "Scratchpad language #{language.inspect} is not runnable"
      end
    end

    def run_ruby(content, cancelled: nil)
      started_at = monotonic_now
      output, status, was_cancelled, truncated = capture_ruby_output(content, cancelled: cancelled)
      Result.new(
        language: :ruby,
        output: output,
        exit_status: was_cancelled ? 130 : status.exitstatus,
        duration: monotonic_now - started_at,
        command: [RbConfig.ruby, "<scratchpad.rb>"],
        cancelled: was_cancelled,
        truncated: truncated
      )
    end

    def capture_ruby_output(content, cancelled: nil)
      Tempfile.create(["kward-scratchpad", ".rb"]) do |file|
        file.write(content.to_s)
        file.flush
        capture_process([RbConfig.ruby, file.path], cancelled: cancelled)
      end
    end

    def capture_process(command, cancelled: nil)
      input, output, wait_thread = Open3.popen2e(*command)
      input.close
      chunks = []
      output_size = 0
      was_cancelled = false

      loop do
        if !was_cancelled && cancelled&.call
          terminate_process(wait_thread.pid)
          was_cancelled = true
        end

        output_size = read_available_output(output, chunks, output_size)
        break if wait_thread.join(0)

        sleep POLL_INTERVAL
      end

      output_size = read_remaining_output(output, chunks, output_size)
      [chunks.join, wait_thread.value, was_cancelled, output_size >= MAX_OUTPUT_BYTES]
    ensure
      if wait_thread&.alive?
        terminate_process(wait_thread.pid)
        wait_thread.join
      end
      input&.close unless input&.closed?
      output&.close unless output&.closed?
    end

    def read_available_output(output, chunks, output_size)
      ready = IO.select([output], nil, nil, 0)
      return output_size unless ready

      loop do
        output_size = append_output(chunks, output.read_nonblock(OUTPUT_READ_SIZE), output_size)
      rescue IO::WaitReadable, EOFError
        break
      end
      output_size
    end

    def read_remaining_output(output, chunks, output_size)
      loop do
        output_size = append_output(chunks, output.read_nonblock(OUTPUT_READ_SIZE), output_size)
      end
    rescue IO::WaitReadable, IOError, EOFError
      output_size
    end

    def append_output(chunks, chunk, output_size)
      return output_size if output_size >= MAX_OUTPUT_BYTES

      remaining = MAX_OUTPUT_BYTES - output_size
      chunks << chunk.byteslice(0, remaining)
      output_size + [chunk.bytesize, remaining].min
    end

    def terminate_process(pid)
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
