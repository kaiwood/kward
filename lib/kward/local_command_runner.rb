require "open3"
require "thread"
require "timeout"
require_relative "cancellation"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Low-level local process runner with bounded capture, timeout, cancellation,
  # and optional output streaming. Callers own command semantics and formatting.
  class LocalCommandRunner
    Result = Struct.new(:stdout, :stderr, :exit_status, :timed_out, :truncated, keyword_init: true)

    READ_SIZE = 4096

    def initialize(timeout_seconds:, max_output_bytes:, terminate_on_output_limit: false)
      @timeout_seconds = timeout_seconds.to_i.positive? ? timeout_seconds.to_i : 30
      @max_output_bytes = max_output_bytes.to_i.positive? ? max_output_bytes.to_i : 128 * 1024
      @terminate_on_output_limit = terminate_on_output_limit
    end

    def run(*command, env: {}, cwd: Dir.pwd, cancellation: nil, unsetenv_others: false, &block)
      cancellation&.raise_if_cancelled!
      stdout_buffer = +""
      stderr_buffer = +""
      captured_bytes = 0
      truncated = false
      timed_out = false
      queue = Queue.new

      Open3.popen3(env.to_h, *command, chdir: cwd.to_s, pgroup: true, unsetenv_others: unsetenv_others) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        readers = [
          read_stream(stdout, :stdout, queue),
          read_stream(stderr, :stderr, queue)
        ]
        cancellation&.on_cancel { terminate_process_group(wait_thread.pid) }

        status = wait_for_process(wait_thread, readers, queue, cancellation: cancellation) do |stream, chunk|
          captured_bytes, truncated, captured_chunk = capture_chunk(
            stream,
            chunk,
            stdout_buffer,
            stderr_buffer,
            captured_bytes,
            truncated
          )
          block&.call(stream, captured_chunk) unless captured_chunk.empty?
          terminate_process_group(wait_thread.pid) if truncated && @terminate_on_output_limit
        end

        join_readers(readers)
        drain_queue(queue) do |stream, chunk|
          captured_bytes, truncated, captured_chunk = capture_chunk(
            stream,
            chunk,
            stdout_buffer,
            stderr_buffer,
            captured_bytes,
            truncated
          )
          block&.call(stream, captured_chunk) unless captured_chunk.empty?
        end

        Result.new(stdout: stdout_buffer, stderr: stderr_buffer, exit_status: status.exitstatus || 1, timed_out: false, truncated: truncated)
      rescue Timeout::Error
        timed_out = true
        terminate_process_group(wait_thread.pid)
        join_readers(readers)
        Result.new(stdout: stdout_buffer, stderr: stderr_buffer, exit_status: nil, timed_out: timed_out, truncated: truncated)
      ensure
        readers&.each { |reader| reader.kill if reader&.alive? }
      end
    end

    private

    def read_stream(io, stream, queue)
      Thread.new do
        loop do
          queue << [stream, io.readpartial(READ_SIZE)]
        rescue EOFError
          break
        end
      end
    end

    def wait_for_process(wait_thread, readers, queue, cancellation:)
      deadline = Time.now + @timeout_seconds
      loop do
        cancellation&.raise_if_cancelled!
        drain_queue(queue) { |stream, chunk| yield(stream, chunk) }
        if wait_thread.join(0.02)
          cancellation&.raise_if_cancelled!
          return wait_thread.value
        end
        raise Timeout::Error if Time.now >= deadline
      end
    rescue Cancellation::CancelledError
      terminate_process_group(wait_thread.pid)
      join_readers(readers)
      raise
    end

    def drain_queue(queue)
      loop do
        stream, chunk = queue.pop(true)
        yield(stream, chunk)
      rescue ThreadError
        break
      end
    end

    def capture_chunk(stream, chunk, stdout_buffer, stderr_buffer, captured_bytes, truncated)
      return [captured_bytes, truncated, ""] if truncated

      remaining = @max_output_bytes - captured_bytes
      if chunk.bytesize > remaining
        truncated = true
        chunk = remaining.positive? ? chunk.byteslice(0, remaining).to_s : ""
      end

      stream == :stderr ? stderr_buffer << chunk : stdout_buffer << chunk
      [captured_bytes + chunk.bytesize, truncated, chunk]
    end

    def join_readers(readers)
      readers.to_a.each { |reader| reader.join(0.1) }
    end

    def terminate_process_group(pid)
      signal_process("TERM", -pid) || signal_process("TERM", pid)
      deadline = Time.now + 0.2
      while Time.now < deadline
        return unless process_running?(pid)

        sleep 0.02
      end
      signal_process("KILL", -pid) || signal_process("KILL", pid)
    end

    def process_running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def signal_process(signal, pid)
      Process.kill(signal, pid)
      true
    rescue Errno::ESRCH, Errno::EINVAL, Errno::EPERM
      false
    end
  end
end
