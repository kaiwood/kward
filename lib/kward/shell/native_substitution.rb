module Kward
  module NativeShell
    # Forked native evaluation shared by subshells and substitutions. No command
    # string crosses an external-shell boundary. Parent state remains authoritative.
    module Substitution
      MAX_CAPTURE_BYTES = 16 * 1024 * 1024

      private

      def fork_program(tree, streams, close: [], group: false, gate: nil, asynchronous: false)
        streams.values.compact.uniq.each(&:flush)
        Process.fork do
          reset_child_state
          Signal.trap("INT", "DEFAULT") unless @traps["INT"] == ""
          if asynchronous
            Signal.trap("INT", "IGNORE")
            Signal.trap("QUIT", "IGNORE")
          end
          if group
            Process.setpgid(0, 0)
            @owned_job_group = Process.getpgrp
          end
          close.each(&:close)
          if gate
            gate.read
            gate.close
          end
          begin
            result = with_signal_handlers { evaluate(tree, streams) }
          rescue Flow => flow
            result = flow.status
          rescue StandardError => e
            streams[2]&.puts("kwsh: #{e.message}")
            result = 2
          end
          wait_builtin([], streams) if @hosted && !@jobs.empty?
          @status = result
          finish(input: streams[0], output: streams[1], error: streams[2])
          streams.values.compact.uniq.each { |io| io.flush rescue nil }
          exit!(@status)
        end
      end

      def subshell(tree, streams)
        pid = fork_program(tree, streams)
        result = wait(pid)
        pid = nil
        result
      ensure
        terminate(pid) if pid
      end

      def capture_substitution(tree)
        reader, writer = IO.pipe
        writer.sync = true
        pid = fork_program(tree, @streams.merge(1 => writer), close: [reader])
        writer.close
        value = +"".b
        begin
          loop do
            value << reader.readpartial(16_384)
            raise ExpansionError, "command substitution exceeds #{MAX_CAPTURE_BYTES} bytes" if value.bytesize > MAX_CAPTURE_BYTES
          end
        rescue EOFError
          # Drain before waiting so output larger than a pipe buffer cannot deadlock.
        end
        @substitution_status = wait(pid)
        pid = nil
        raise ExpansionError, "NUL bytes in command substitution are not supported" if value.include?("\0")
        value.force_encoding(Encoding.default_external).sub(/\n+\z/, "")
      ensure
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        terminate(pid) if pid
      end

      def process_substitution(direction, tree)
        raise ExpansionError, "process substitution requires a simple command" unless @process_substitutions
        reader, writer = IO.pipe
        parent, child = direction == "<" ? [reader, writer] : [writer, reader]
        parent.nonblock = false
        child.nonblock = false
        child.sync = true
        pid = fork_program(tree, @streams.merge(direction == "<" ? 1 : 0 => child), close: [parent])
        child.close
        parent.close_on_exec = false
        @process_substitutions << [parent, pid]
        "/dev/fd/#{parent.fileno}"
      rescue StandardError
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        terminate(pid) if pid
        raise
      end

      def finish_substitutions(resources)
        resources.each { |io, _| io.close unless io.closed? }
        pending = resources.map(&:last)
        until pending.empty?
          wait(pending.first)
          pending.shift
        end
      ensure
        pending&.each { |pid| terminate(pid) }
      end
    end
  end
end
