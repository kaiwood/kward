require "io/console"
require "pty"
require "timeout"
require_relative "cancellation"
require_relative "local_command_runner"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Low-level pseudo-terminal command runner with bounded capture, timeout,
  # cancellation, and optional output streaming. This gives child processes a
  # TTY without trying to emulate an interactive terminal.
  class LocalPtyCommandRunner
    Result = LocalCommandRunner::Result

    READ_SIZE = 4096
    DEFAULT_ROWS = 24
    DEFAULT_COLUMNS = 80

    def initialize(timeout_seconds:, max_output_bytes:, terminate_on_output_limit: false)
      @timeout_seconds = timeout_seconds.to_i.positive? ? timeout_seconds.to_i : 30
      @max_output_bytes = max_output_bytes.to_i.positive? ? max_output_bytes.to_i : 128 * 1024
      @terminate_on_output_limit = terminate_on_output_limit
    end

    def run(*command, env: {}, cwd: Dir.pwd, cancellation: nil, &block)
      cancellation&.raise_if_cancelled!
      output = +""
      captured_bytes = 0
      truncated = false
      timed_out = false
      cancelled = false
      pid = nil
      status = nil

      PTY.spawn(env.to_h, *command, chdir: cwd.to_s) do |reader, _writer, child_pid|
        pid = child_pid
        configure_window_size(reader)
        cancellation&.on_cancel do
          cancelled = true
          terminate_process_group(pid)
        end

        begin
          deadline = Time.now + @timeout_seconds
          loop do
            cancellation&.raise_if_cancelled!
            raise Timeout::Error if Time.now >= deadline

            readable, = IO.select([reader], nil, nil, 0.02)
            next unless readable

            chunk = read_chunk(reader)
            break if chunk.nil?

            chunk = normalize_line_endings(chunk)
            captured_bytes, truncated, captured_chunk = capture_chunk(chunk, output, captured_bytes, truncated)
            block&.call(:stdout, captured_chunk) unless captured_chunk.empty?
            terminate_process_group(pid) if truncated && @terminate_on_output_limit
          end
        rescue Errno::EIO
          nil
        end

        status = wait_for_status(pid)
      end

      cancellation&.raise_if_cancelled! if cancelled
      Result.new(stdout: output, stderr: "", exit_status: exit_status(status), timed_out: false, truncated: truncated)
    rescue Timeout::Error
      timed_out = true
      terminate_process_group(pid) if pid
      wait_for_status(pid) if pid
      Result.new(stdout: output, stderr: "", exit_status: nil, timed_out: timed_out, truncated: truncated)
    rescue Cancellation::CancelledError
      terminate_process_group(pid) if pid
      wait_for_status(pid) if pid
      raise
    end

    private

    def configure_window_size(reader)
      rows, columns = terminal_window_size
      reader.winsize = [rows, columns]
    rescue StandardError
      nil
    end

    def terminal_window_size
      rows, columns = IO.console&.winsize
      rows = DEFAULT_ROWS unless rows.to_i.positive?
      columns = DEFAULT_COLUMNS unless columns.to_i.positive?
      [rows, columns]
    rescue StandardError
      [DEFAULT_ROWS, DEFAULT_COLUMNS]
    end

    def read_chunk(reader)
      reader.read_nonblock(READ_SIZE, exception: false).tap do |chunk|
        return nil if chunk.nil?
        return nil if chunk == :wait_readable
      end
    end

    def normalize_line_endings(chunk)
      chunk.gsub("\r\r\n", "\n").gsub("\r\n", "\n")
    end

    def capture_chunk(chunk, output, captured_bytes, truncated)
      return [captured_bytes, truncated, ""] if truncated

      remaining = @max_output_bytes - captured_bytes
      if chunk.bytesize > remaining
        truncated = true
        chunk = remaining.positive? ? chunk.byteslice(0, remaining).to_s : ""
      end

      output << chunk
      [captured_bytes + chunk.bytesize, truncated, chunk]
    end

    def wait_for_status(pid)
      return unless pid

      _, status = Process.wait2(pid)
      status
    rescue Errno::ECHILD
      nil
    end

    def exit_status(status)
      return 1 unless status
      return status.exitstatus if status.exited?
      return 128 + status.termsig if status.signaled?

      1
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
