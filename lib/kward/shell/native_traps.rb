module Kward
  module NativeShell
    # Signal callbacks only enqueue names. Native source runs at interpreter safe
    # points, with the interrupted status restored unless the action exits.
    module Traps
      def finish(input: $stdin, output: $stdout, error: $stderr)
        streams = { 0 => input, 1 => output, 2 => error }.merge(@persistent_descriptors)
        action = @traps.delete("EXIT")
        with_signal_handlers { run_trap(action, streams) } if action && !action.empty?
        @status
      rescue Flow => flow
        @status = flow.status
      rescue SyntaxError, ExpansionError, ExecutionError, SystemCallError, IOError, ArgumentError => e
        error&.puts("kwsh: #{e.message}")
        @status = 2
      end

      def with_signals
        with_signal_handlers { yield }
      end

      def poll_signals(input: $stdin, output: $stdout, error: $stderr)
        run_pending_traps({ 0 => input, 1 => output, 2 => error }.merge(@persistent_descriptors))
      rescue Flow => flow
        @exited = true if flow.kind == :exit
        @status = flow.status
      rescue SyntaxError, ExpansionError, ExecutionError, SystemCallError, IOError, ArgumentError => e
        error&.puts("kwsh: #{e.message}")
        @status = 2
      end

      private

      def signal_name(value)
        value = value.to_s.sub(/\ASIG/, "")
        name = value.match?(/\A[0-9]+\z/) ? Signal.list.key(value.to_i) : value
        raise ExecutionError, "invalid signal: #{value}" unless name && Signal.list.key?(name)
        name
      end

      def trap_builtin(args, streams)
        args.shift if args.first == "--"
        if args.empty? || args.first == "-p"
          args.shift if args.first == "-p"
          names = args.empty? ? @traps.keys : args.map { |name| signal_name(name) }
          names.each do |name|
            write_line(streams, "trap -- #{Shellwords.escape(@traps[name])} #{name}") if @traps.key?(name)
          end
          return 0
        end
        action = args.first.match?(/\A[0-9]+\z/) ? "-" : args.shift
        raise ExecutionError, "trap: expected an action and signals" if args.empty?
        names = args.map { |name| signal_name(name) }
        if @interactive && !@job_child && names.include?("USR2")
          raise ExecutionError, "USR2 is reserved for hosted shell shutdown"
        end
        raise ExecutionError, "trap: KILL and STOP cannot be trapped" if (names & %w[KILL STOP]).any?
        names.each do |name|
          action == "-" ? @traps.delete(name) : @traps[name] = action
          install_signal(name) unless name == "EXIT"
        end
        0
      end

      def install_signal(name)
        return unless @saved_signals
        handler = if !@traps.key?(name)
          @saved_signals.fetch(name, "DEFAULT")
        elsif @traps[name].empty?
          "IGNORE"
        else
          proc do
            unless name == "CHLD" && @active_signal == "CHLD" || @pending_signals.include?(name)
              @pending_signals << name
            end
          end
        end
        previous = Signal.trap(name, handler)
        @saved_signals[name] = previous unless @saved_signals.key?(name)
      end

      def with_signal_handlers
        return yield if @saved_signals
        @saved_signals = {}
        begin
          @traps.each_key { |name| install_signal(name) unless name == "EXIT" }
          yield
        ensure
          @saved_signals.each { |name, handler| Signal.trap(name, handler) }
          @saved_signals = nil
        end
      end

      def run_trap(action, streams)
        saved = @status
        evaluate(Parser.parse(action, aliases: @aliases), streams, ignored: true)
        @status = saved
      end

      def run_pending_traps(streams)
        return if @running_trap
        @running_trap = true
        begin
          signals = @pending_signals
          @pending_signals = []
          signals.each do |signal|
            @active_signal = signal
            action = @traps[signal]
            run_trap(action, streams) if action && !action.empty?
          end
        ensure
          @active_signal = nil
          @running_trap = false
        end
      end

      def reset_child_state(job_group: @owned_job_group)
        %w[INT TERM HUP USR2].each do |name|
          previous = Signal.trap(name, "DEFAULT")
          Signal.trap(name, "IGNORE") if previous == "IGNORE"
        end
        %w[TSTP TTIN TTOU].each { |name| Signal.trap(name, "DEFAULT") } if @interactive
        @traps.each do |name, action|
          Signal.trap(name, action.empty? ? "IGNORE" : "DEFAULT") unless name == "EXIT"
        end
        @traps = @traps.select { |name, action| name != "EXIT" && action.empty? }
        @pending_signals = []
        @saved_signals = nil
        @jobs = {}
        @active_streams = []
        @last_background_pid = nil
        @job_child = true
        @owned_job_group = job_group
        @options.delete("monitor")
        @replace_process = !@interactive
        @loop_depth = 0
        @function_depth = 0
        @process_substitutions = nil
      end
    end
  end
end
