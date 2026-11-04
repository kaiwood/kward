require "io/console"

module Kward
  module NativeShell
    # Each job has an owned process group. Only its interpreter leader is reaped
    # here; that interpreter owns the pipeline and substitution children.
    module Jobs
      Job = Struct.new(:id, :pid, :group, :state, :status, :command, :terminal_mode, keyword_init: true)
      MAX_JOBS = 1_024
      TCSETPGRP = Fiddle::Function.new(Fiddle::Handle::DEFAULT["tcsetpgrp"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT)

      def close
        active = @jobs.values.reject { |job| job.state == :done }
        active.each do |job|
          signal_job(job, "HUP")
          signal_job(job, "CONT")
          signal_job(job, "KILL")
        end
        active.each do |job|
          begin
            Process.waitpid(job.pid)
          rescue Errno::ECHILD
            # A completed job may already have been collected by its waiter.
          end
        end
        @jobs.clear
        @owned_descriptors.each { |io| io.close unless io.closed? }
        @owned_descriptors.clear
      end

      private

      def foreground_process?(node)
        commands = node.values.first
        commands.length > 1 || commands.first.kind == :subshell
      end

      def job_description(tree)
        return tree.source if tree.source
        return job_description(tree.values.first) if tree.kind == :and_or
        tree.kind.to_s
      end

      def start_job(tree, streams, background:)
        reap_jobs
        raise ExecutionError, "too many jobs (maximum #{MAX_JOBS}); use wait" if @jobs.size >= MAX_JOBS
        reader, writer = IO.pipe
        null = File.open(File::NULL) if background && !@options.include?("monitor")
        selected = null ? streams.merge(0 => null) : streams
        group = !@job_child
        pid = fork_program(tree, selected, close: [writer], group: group, gate: reader,
                           asynchronous: background && !@options.include?("monitor"))
        reader.close
        Process.setpgid(pid, pid) if group
        id = (@jobs.keys.max || 0) + 1
        job = Job.new(id: id, pid: pid, group: group, state: :running, command: job_description(tree))
        @jobs[job.id] = job
        if background
          @last_background_pid = pid
          writer.close
          0
        else
          foreground_job(job, streams, gate: writer)
        end
      ensure
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        null&.close
        terminate(pid) if pid && !job
      end

      def signal_job(job, signal)
        Process.kill(signal == "EXIT" ? 0 : signal, job.group ? -job.pid : job.pid)
        job.state = :running if signal == "CONT"
      rescue Errno::ESRCH
        nil
      end

      def update_job(job, status)
        if status.stopped?
          job.state = :stopped
          job.status = 128 + status.stopsig
        else
          job.state = :done
          job.status = status.exitstatus || 128 + status.termsig
        end
      end

      def reap_jobs
        @jobs.each_value do |job|
          next if job.state == :done
          result = Process.waitpid2(job.pid, Process::WNOHANG | Process::WUNTRACED)
          update_job(job, result.last) if result
        end
      end

      def find_job(value)
        reap_jobs
        if %w[% %% %+].include?(value)
          @jobs.values.last
        elsif value == "%-"
          @jobs.values[-2]
        elsif value.match?(/\A%[0-9]+\z/)
          @jobs[value[1..].to_i]
        elsif value.match?(/\A[0-9]+\z/)
          @jobs.values.find { |job| job.pid == value.to_i }
        elsif value.start_with?("%")
          matches = @jobs.values.select do |job|
            value.start_with?("%?") ? job.command.include?(value[2..]) : job.command.start_with?(value[1..])
          end
          raise ExecutionError, "ambiguous job: #{value}" if matches.length > 1
          matches.first
        end
      end

      def wait_job(job, streams, stopped: false, interruptible: false)
        until job.state == :done || stopped && job.state == :stopped
          if interruptible && !@pending_signals.empty?
            signal = @pending_signals.first
            run_pending_traps(streams)
            return 128 + Signal.list.fetch(signal)
          end
          result = Process.waitpid2(job.pid, Process::WNOHANG | Process::WUNTRACED)
          result ? update_job(job, result.last) : sleep(0.01)
        end
        @jobs.delete(job.id) if job.state == :done
        job.status
      end

      def foreground_job(job, streams, gate: nil)
        # A command may redirect stdin and still open /dev/tty (for example less).
        terminal = [streams[0], $stdin].compact.find(&:tty?) if job.group
        previous_ttou = Signal.trap("TTOU", "IGNORE") if terminal
        shell_mode = terminal.console_mode if terminal
        if terminal && TCSETPGRP.call(terminal.fileno, job.pid) < 0
          raise SystemCallError.new("tcsetpgrp", Fiddle.last_error)
        end
        terminal.console_mode = job.terminal_mode if terminal && job.terminal_mode
        gate&.close
        if job.state == :stopped
          job.state = :running
          signal_job(job, "CONT")
        end
        result = wait_job(job, streams, stopped: true)
        job.terminal_mode = terminal.console_mode if terminal && job.state == :stopped
        @pending_signals << "INT" if result == 130 && @traps.key?("INT")
        result
      rescue Interrupt
        signal_job(job, "INT")
        raise
      ensure
        if terminal
          begin
            TCSETPGRP.call(terminal.fileno, Process.getpgrp)
            terminal.console_mode = shell_mode if shell_mode && (job.state == :stopped || !result || result >= 128)
          ensure
            Signal.trap("TTOU", previous_ttou)
          end
        end
      end

      def jobs_builtin(args, streams)
        mode = args.first&.start_with?("-") ? args.shift : nil
        raise ExecutionError, "jobs: expected -l, -p, -r, or -s" if mode && !%w[-l -p -r -s].include?(mode)
        reap_jobs
        jobs = args.empty? ? @jobs.values : args.map { |arg| find_job(arg) || raise(ExecutionError, "jobs: no such job: #{arg}") }
        jobs.each do |job|
          next if mode == "-r" && job.state != :running || mode == "-s" && job.state != :stopped
          text = mode == "-p" ? job.pid.to_s : "[#{job.id}] #{mode == '-l' ? "#{job.pid} " : ''}#{job.state.to_s.capitalize} #{job.command}"
          write_line(streams, text)
        end
        0
      end

      def wait_builtin(args, streams)
        args.shift if args.first == "--"
        raise ExecutionError, "wait: unsupported option" if args.any? { |arg| arg.start_with?("-") }
        all = args.empty?
        targets = all ? @jobs.values.dup : args.map { |arg| find_job(arg) }
        result = 0
        targets.each do |job|
          result = job ? wait_job(job, streams, interruptible: true) : 127
          return result if job && @jobs.key?(job.id)
        end
        all ? 0 : result
      end

      def resume_job(args, streams, foreground:)
        raise ExecutionError, "job control is disabled; use set -m" unless @options.include?("monitor")
        raise ExecutionError, "expected at most one job ID" if args.length > 1
        job = find_job(args.first || "%+")
        raise ExecutionError, "no such active job" unless job && job.state != :done
        return foreground_job(job, streams) if foreground
        signal_job(job, "CONT")
        job.state = :running
        0
      end

      def kill_builtin(args, streams)
        signal = "TERM"
        if args.first == "-l"
          args.shift
          text = args.empty? ? Signal.list.keys.reject { |name| name == "EXIT" }.join(" ") : args.map { |arg| arg.match?(/\A[0-9]+\z/) ? signal_name(arg.to_i > 128 ? (arg.to_i - 128).to_s : arg) : Signal.list.fetch(signal_name(arg)).to_s }.join(" ")
          write_line(streams, text)
          return 0
        elsif %w[-s -n].include?(args.first)
          args.shift
          signal = signal_name(args.shift)
        elsif args.first&.start_with?("-") && args.first != "--"
          signal = signal_name(args.shift[1..])
        end
        args.shift if args.first == "--"
        raise ExecutionError, "kill: expected a pid or job ID" if args.empty?
        args.each do |target|
          if target.start_with?("%")
            job = find_job(target)
            raise ExecutionError, "kill: no such active job: #{target}" unless job && job.state != :done
            signal_job(job, signal)
          else
            unless target.match?(/\A-?[0-9]{1,10}\z/) && target.to_i.abs <= 2_147_483_647
              raise ExecutionError, "kill: invalid pid: #{target}"
            end
            Process.kill(signal == "EXIT" ? 0 : signal, target.to_i)
          end
        end
        0
      end
    end
  end
end
