require "io/console"
require "pty"
require "timeout"
require_relative "local_pty_command_runner"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Runs a command in a PTY while forwarding caller-owned input and output IOs.
  # This is intentionally low level: UI orchestration decides when terminal
  # ownership is handed to the child process and how the result is presented.
  class InteractivePtyRunner
    Result = Struct.new(:exit_status, keyword_init: true)

    READ_SIZE = 4096

    def initialize(window_size_provider: nil)
      @window_size_provider = window_size_provider
      @window_size = nil
    end

    def run(*command, env: {}, cwd: Dir.pwd, input: $stdin, output: $stdout)
      pid = nil
      status = nil

      PTY.spawn(env.to_h, *command, chdir: cwd.to_s) do |reader, writer, child_pid|
        pid = child_pid
        update_window_size(reader, pid)
        with_raw_input(input) do
          drain_initial_input(input, writer)
          loop do
            update_window_size(reader, pid)
            readable = IO.select([reader, input], nil, nil, 0.02)&.first || []
            forward_pty_output(reader, output) if readable.include?(reader)
            forward_input(input, writer) if readable.include?(input)
            if (finished_status = finished_status(pid))
              status = finished_status
              break
            end
          rescue Errno::EIO, IOError
            break
          end
        end
        status ||= wait_for_status(pid)
      ensure
        writer&.close unless writer&.closed?
      end

      Result.new(exit_status: exit_status(status))
    end

    private

    def with_raw_input(input)
      return yield unless input.respond_to?(:raw)

      input.raw { yield }
    rescue Errno::ENOTTY
      yield
    end

    def drain_initial_input(input, writer)
      loop do
        chunk = input.read_nonblock(READ_SIZE, exception: false)
        break if chunk.nil? || chunk == :wait_readable

        writer.write(chunk)
      end
      writer.flush
    rescue Errno::EIO, Errno::EPIPE, IOError
      nil
    end

    def forward_pty_output(reader, output)
      chunk = reader.read_nonblock(READ_SIZE, exception: false)
      return if chunk.nil? || chunk == :wait_readable

      output.write(chunk)
      output.flush if output.respond_to?(:flush)
    end

    def forward_input(input, writer)
      chunk = input.read_nonblock(READ_SIZE, exception: false)
      return if chunk.nil? || chunk == :wait_readable

      writer.write(chunk)
      writer.flush
    rescue Errno::EIO, Errno::EPIPE, IOError
      nil
    end

    def update_window_size(reader, pid)
      window_size = terminal_window_size
      return if window_size == @window_size

      @window_size = window_size
      reader.winsize = window_size
      signal_process("WINCH", -pid) || signal_process("WINCH", pid)
    rescue StandardError
      nil
    end

    def terminal_window_size
      rows, columns = @window_size_provider ? @window_size_provider.call : IO.console&.winsize
      rows = LocalPtyCommandRunner::DEFAULT_ROWS unless rows.to_i.positive?
      columns = LocalPtyCommandRunner::DEFAULT_COLUMNS unless columns.to_i.positive?
      [rows, columns]
    rescue StandardError
      [LocalPtyCommandRunner::DEFAULT_ROWS, LocalPtyCommandRunner::DEFAULT_COLUMNS]
    end

    def finished_status(pid)
      return unless pid

      finished_pid, status = Process.wait2(pid, Process::WNOHANG)
      status if finished_pid
    rescue Errno::ECHILD
      nil
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
