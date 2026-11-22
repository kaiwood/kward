require "io/console"
require "pty"
require "json"
require "socket"
require_relative "../terminal/ansi"
require_relative "../terminal/keys"
require_relative "../pty/adaptive_output_sink"
require_relative "../pty/transcript_normalizer"
require_relative "../cancellation"

module Kward
  module NativeShell
    # The inner PTY is the shell's controlling terminal; the launcher only
    # relays bytes, resizes it, and retains a bounded pre-input snapshot.
    class StandaloneTerminal
      CHANNEL_FD = 30
      CAPTURE_BYTES = 32_000
      CHUNK_BYTES = 16_384
      POLL_SECONDS = 0.05

      def run(ruby_arguments, descriptors)
        @lock = Mutex.new
        @pending_input = +"".b
        @null = File.open(File::NULL, "w")
        @channel, child = UNIXSocket.pair
        @channel.sync = true
        @reader, @writer, @pid = PTY.spawn(color_defaults, *ruby_arguments, descriptors.merge(CHANNEL_FD => child))
        child.close
        @writer.sync = true
        @reader.console_mode = $stdin.console_mode
        resize
        handlers = %w[HUP TERM INT].to_h do |signal|
          [signal, Signal.trap(signal) { @signal = signal }]
        end
        $stdin.raw(intr: false) do
          server = Thread.new { serve }
          server.report_on_exception = false
          begin
            relay
          ensure
            @channel.shutdown rescue nil
            server.kill
            server.join
          end
        end
        @reader.close
        @writer.close
        reap_child
        @status&.exitstatus || (@status&.termsig && 128 + @status.termsig) || 1
      ensure
        handlers&.each { |signal, handler| Signal.trap(signal, handler) }
        [@reader, @writer, @channel, child, @null].compact.each { |io| io.close unless io.closed? }
        reap_child
      end

      private

      def color_defaults
        return {} if ENV["TERM"] == "dumb" || !ANSI.enabled?

        defaults = {}
        defaults["CLICOLOR"] = "1" unless ENV.key?("CLICOLOR")
        defaults["COLORTERM"] = "truecolor" unless ENV.key?("COLORTERM")
        defaults["TERM"] = "xterm-256color" if ENV["TERM"].to_s.empty?
        defaults
      end

      def relay
        loop do
          resize
          if @signal
            Process.kill(@signal, @pid) rescue nil
            break if @signal == "HUP"
            @signal = nil
          end
          readers = [@reader]
          readers << $stdin if @pending_input.bytesize < CHUNK_BYTES
          writers = [@writer] unless @pending_input.empty?
          ready = IO.select(readers, writers, nil, POLL_SECONDS)
          @lock.synchronize { drain_output(1) } if ready&.first&.include?(@reader)
          forward_input if ready&.first&.include?($stdin)
          @lock.synchronize { flush_input } if ready&.[](1)&.include?(@writer)
          _, @status = Process.waitpid2(@pid, Process::WNOHANG)
          break if @status
        end
      rescue EOFError, Errno::EIO, Errno::EPIPE
        # Closing the PTY or its real terminal ends the relay.
      ensure
        @lock.synchronize { drain_output } rescue nil
      end

      def reap_child
        return unless @pid && !@status

        # EOF from a fast exec can precede its wait status. Give it a chance
        # to exit normally before falling back to cleanup after terminal loss.
        10.times do
          _, @status = Process.waitpid2(@pid, Process::WNOHANG)
          return if @status
          sleep 0.01
        end
        Process.kill("KILL", @pid)
        _, @status = Process.waitpid2(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def resize
        size = $stdin.winsize
        return if size == @size || size.any?(&:zero?)

        @reader.winsize = size
        @size = size
      rescue Errno::EIO
        nil
      end

      def forward_input
        bytes = $stdin.read_nonblock(CHUNK_BYTES, exception: false)
        raise EOFError unless bytes
        return if bytes == :wait_readable

        cancellation, running = @lock.synchronize do
          if @cancellation
            [@cancellation, @agent_running]
          else
            drain_output
            @capture&.input_forwarded
            @pending_input << bytes
            [nil, nil]
          end
        end
        return unless cancellation && bytes.include?(TerminalKeys::CTRL_C)

        cancellation.cancel!
        Process.kill("INT", @pid) if running
      end

      def flush_input
        return if @pending_input.empty?

        # A full slave input queue must not block relaying command output.
        length = @writer.write_nonblock(@pending_input, exception: false)
        @pending_input = @pending_input.byteslice(length..) if length.is_a?(Integer)
      end

      def drain_output(limit = 64)
        limit.times do
          chunk = @reader.read_nonblock(CHUNK_BYTES, exception: false)
          break unless chunk.is_a?(String)

          write_terminal(chunk)
          @capture&.write(chunk)
        end
      rescue Errno::EIO
        nil
      end

      def write_terminal(bytes)
        $stdout.write(bytes)
        $stdout.flush
        @at_line_start = bytes.end_with?("\n")
      end

      def start_capture
        @capture = AdaptivePtyOutputSink.new(output: @null, on_exclusive: -> {}, max_capture_bytes: CAPTURE_BYTES)
      end

      def stop_capture
        drain_output
        sink, @capture = @capture, nil
        sink.finish
        return "" unless sink.transcript_safe? && !sink.preserve_terminal_view?

        raw = ANSI.normalize_transcript_encoding(sink.captured_output).gsub("\r\n", "\n")
        PtyTranscriptNormalizer.normalize(raw, columns: @size&.last || 80, max_bytes: CAPTURE_BYTES).to_s
      end

      def serve
        while (line = @channel.gets)
          message = JSON.parse(line)
          case message.fetch("type")
          when "ready"
            respond("ok")
          when "begin"
            @lock.synchronize do
              drain_output
              @last_command = message.fetch("command")
              start_capture
              @capture.input_forwarded if message["input_pending"] || !@pending_input.empty?
            end
            respond("ok")
          when "finish"
            @lock.synchronize do
              @last_output = stop_capture
              @status_of_command = message.fetch("status")
            end
            respond("ok")
          when "clear_context"
            @lock.synchronize { @capture = @last_command = @last_output = @status_of_command = nil }
            respond("ok")
          when "ask" then answer(message)
          end
        end
      rescue EOFError, Errno::EPIPE, IOError
        nil
      ensure
        @channel.shutdown rescue nil
      end

      def answer(message)
        @cwd = message.fetch("cwd")
        @lock.synchronize do
          @pending_input = +"".b
          @cancellation = Cancellation.new
        end
        require_relative "standalone_agent"
        @agent ||= StandaloneAgent.new
        text, draft = @agent.ask(message.fetch("instruction"), self, cancellation: @cancellation)
        @cancellation.raise_if_cancelled!
        finish_answer(ANSI.sanitize_transcript(text), draft: draft)
      rescue Cancellation::CancelledError
        finish_answer("Canceled.")
      rescue LoadError, StandardError => e
        finish_answer(ANSI.sanitize_transcript("Shell agent: #{e.message}"))
      end

      def finish_answer(text, draft: nil)
        @lock.synchronize do
          @cancellation = nil
          respond("answer", text: text, draft: draft)
        end
      end

      def respond(type, **data)
        @channel.puts(JSON.generate(data.merge(type: type)))
      end

      public

      attr_reader :cwd

      def context_snapshot
        { cwd: @cwd, last_command: @last_command, last_output: @last_output, exit_status: @status_of_command }
      end

      def timeout_seconds
        Kwsh::DEFAULT_TIMEOUT_SECONDS
      end

      def run_for_agent(command, timeout_seconds: nil, cancellation: nil)
        cancellation&.raise_if_cancelled!
        respond("run", command: command, timeout: timeout_seconds || self.timeout_seconds)
        JSON.parse(@channel.readline).fetch("type") == "running" or raise IOError, "Shell agent command did not start"
        @lock.synchronize do
          drain_output
          start_capture
          @agent_running = true
          respond("ok")
        end
        Process.kill("INT", @pid) if cancellation&.cancelled?
        result = JSON.parse(@channel.readline)
        @cwd = result.fetch("cwd")
        output = @lock.synchronize do
          captured = stop_capture
          write_terminal("\r\n") unless @at_line_start
          captured
        end
        @last_command, @last_output, @status_of_command = command, output, result.fetch("status")
        cancellation&.raise_if_cancelled!
        Kwsh::Result.new(output: output, exit_status: @status_of_command)
      ensure
        @lock.synchronize do
          @agent_running = false
          @capture = nil
        end
      end
    end
  end
end
