require "io/console"
require "pty"
require "timeout"
require_relative "local_pty_command_runner"
require_relative "pty_output_sink"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Runs a command in a PTY while forwarding caller-owned input and output sink.
  # This is intentionally low level: UI orchestration decides when terminal
  # ownership is handed to the child process and how the result is presented.
  class InteractivePtyRunner
    Result = Struct.new(:exit_status, :input_forwarded, keyword_init: true)

    READ_SIZE = 4096

    def initialize(window_size_provider: nil)
      @window_size_provider = window_size_provider
      @window_size = nil
    end

    def run(*command, env: {}, cwd: Dir.pwd, input: $stdin, sink:)
      pid = nil
      status = nil
      writer = nil
      input_forwarded = false

      PTY.spawn(env.to_h, *command, chdir: cwd.to_s) do |reader, child_writer, child_pid|
        pid = child_pid
        writer = child_writer
        update_window_size(reader, pid)
        with_raw_input(input) do
          input_forwarded = drain_initial_input(input, writer, sink)
          status, forwarded = forward_io(reader, writer, pid, input, sink)
          input_forwarded ||= forwarded
        end
        sink.finish if sink.respond_to?(:finish)
        status ||= wait_for_status(pid)
      end

      Result.new(exit_status: exit_status(status), input_forwarded: input_forwarded)
    ensure
      writer&.close unless writer&.closed?
      terminate_and_reap(pid) if pid && status.nil?
    end

    private

    def with_raw_input(input)
      return yield unless input.respond_to?(:raw)

      yielded = false
      input.raw do
        yielded = true
        yield
      end
    rescue Errno::ENOTTY
      raise if yielded

      yield
    end

    def drain_initial_input(input, writer, sink)
      forwarded = false
      loop do
        chunk = input.read_nonblock(READ_SIZE, exception: false)
        break if chunk.nil? || chunk == :wait_readable

        sink.input_forwarded if sink.respond_to?(:input_forwarded)
        writer.write(chunk)
        forwarded = true
      end
      writer.flush
      forwarded
    rescue Errno::EIO, Errno::EPIPE, IOError
      forwarded
    end

    def forward_io(reader, writer, pid, input, sink)
      input_open = true
      input_forwarded = false
      loop do
        update_window_size(reader, pid)
        readers = [reader]
        readers << input if input_open
        readable = IO.select(readers, nil, nil, 0.02)&.first || []
        forward_pty_output(reader, sink) if readable.include?(reader)
        if input_open && readable.include?(input)
          input_open, forwarded = forward_input(input, writer, sink)
          input_forwarded ||= forwarded
        end

        status = finished_status(pid)
        next unless status

        return [finish_stopped_process(pid), input_forwarded] if status.stopped?

        drain_pty_output(reader, sink)
        return [status, input_forwarded]
      rescue Errno::EIO
        return [wait_for_status(pid), input_forwarded]
      end
    end

    def forward_pty_output(reader, sink)
      chunk = reader.read_nonblock(READ_SIZE, exception: false)
      return if chunk.nil? || chunk == :wait_readable

      sink.write(chunk)
      sink.flush if sink.respond_to?(:flush)
    end

    def drain_pty_output(reader, sink)
      loop do
        readable, = IO.select([reader], nil, nil, 0.02)
        break unless readable

        chunk = reader.read_nonblock(READ_SIZE, exception: false)
        break if chunk.nil? || chunk == :wait_readable

        sink.write(chunk)
      end
      sink.flush if sink.respond_to?(:flush)
    rescue Errno::EIO
      nil
    end

    def forward_input(input, writer, sink)
      chunk = input.read_nonblock(READ_SIZE, exception: false)
      return [false, false] if chunk.nil?
      return [true, false] if chunk == :wait_readable

      sink.input_forwarded if sink.respond_to?(:input_forwarded)
      writer.write(chunk)
      writer.flush
      [true, true]
    rescue Errno::EIO, Errno::EPIPE, IOError
      [false, false]
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

      finished_pid, status = Process.wait2(pid, Process::WNOHANG | Process::WUNTRACED)
      status if finished_pid
    rescue Errno::ECHILD
      nil
    end

    def finish_stopped_process(pid)
      signal_process("CONT", -pid) || signal_process("CONT", pid)
      terminate_process_group(pid)
      wait_for_status(pid)
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

    def terminate_and_reap(pid)
      terminate_process_group(pid)
      wait_for_status(pid)
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
