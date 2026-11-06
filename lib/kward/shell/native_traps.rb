module Kward
  module NativeShell
    # Signal callbacks only enqueue names. Native source runs at interpreter safe
    # points, with the interrupted status restored unless the action exits.
    module Traps
      INTERACTIVE_SIGNALS = %w[INT QUIT TERM TSTP TTIN TTOU].freeze
      RUBY_RESERVED_SIGNALS = %w[ILL FPE BUS SEGV VTALRM].freeze

      def with_prompt_input
        @reading_prompt = true
        yield
      ensure
        @reading_prompt = false
      end

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
        notify_jobs(error: error)
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
        number = value.match?(/\A[0-9]+\z/) ? value.to_i : Signal.list[value]
        name = Signal.list.key(number)
        raise InvalidSignal, "invalid signal: #{value}" unless name && Signal.list.key?(name)
        name
      end

      def trap_builtin(args, streams)
        defaults = args.first == "-p"
        args.shift if defaults
        args.shift if args.first == "--"
        if args.empty? || defaults
          actions = @trap_snapshot || @traps
          names = if args.empty?
            defaults ? Signal.list.values.uniq.map { |number| Signal.list.key(number) } - %w[KILL STOP] : actions.keys
          else
            args.map { |name| signal_name(name) }
          end
          reserved_shutdown = @trap_snapshot ? @trap_snapshot_hosted : @hosted && !@job_child
          names -= ["USR2"] if reserved_shutdown
          names.each do |name|
            write_line(streams, "trap -- #{Shellwords.escape(actions.fetch(name, '-'))} #{name}")
          end
          @trap_snapshot = nil unless args.empty?
          return 0
        end
        action = args.first.match?(/\A[0-9]+\z/) ? "-" : args.shift
        raise ExecutionError, "trap: expected an action and signals" if args.empty?
        names = args.map { |name| signal_name(name) }
        if @hosted && !@job_child && names.include?("USR2")
          raise ExecutionError, "USR2 is reserved for hosted shell shutdown"
        end
        raise ExecutionError, "trap: KILL and STOP cannot be trapped" if action != "-" && (names & %w[KILL STOP]).any?
        @trap_snapshot = nil
        names.each do |name|
          next if %w[KILL STOP].include?(name)
          next if !interactive_scope? && @entry_ignored.include?(name)
          if RUBY_RESERVED_SIGNALS.include?(name) && action != "-"
            raise ExecutionError, "trap: #{name} is reserved by the Ruby runtime"
          end
          changed = @traps.key?(name) || action != "-"
          @entry_ignored.delete(name) if interactive_scope?
          action == "-" ? @traps.delete(name) : @traps[name] = action
          install_signal(name) if changed && name != "EXIT"
        end
        0
      rescue InvalidSignal => e
        streams[2]&.puts("kwsh: #{e.message}")
        1
      end

      def child_signal_dispositions
        INTERACTIVE_SIGNALS.to_h do |name|
          [name, @traps[name] == "" ? "IGNORE" : "DEFAULT"]
        end
      end

      def default_signal_handler(name)
        if !@hosted && interactive_scope? && INTERACTIVE_SIGNALS.include?(name)
          name == "INT" ? proc { raise Interrupt if @reading_prompt } : "IGNORE"
        elsif @hosted && !@job_child
          @saved_signals.fetch(name, "DEFAULT")
        else
          "DEFAULT"
        end
      end

      def install_signal(name)
        return unless @saved_signals
        return if RUBY_RESERVED_SIGNALS.include?(name)
        handler = if !@traps.key?(name)
          default_signal_handler(name)
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
          names = @traps.keys
          names |= INTERACTIVE_SIGNALS if !@hosted && interactive_scope?
          names.each { |name| install_signal(name) unless name == "EXIT" }
          yield
        ensure
          @saved_signals.each { |name, handler| Signal.trap(name, handler || "DEFAULT") }
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
        # Inspection retains the parent actions until a trap command supplies
        # operands; execution uses reset dispositions immediately.
        unless @trap_snapshot
          @trap_snapshot = @traps.dup
          @trap_snapshot_hosted = @hosted && !@job_child
        end
        names = (@saved_signals || {}).keys | @traps.keys | INTERACTIVE_SIGNALS | %w[HUP USR2]
        @traps = @traps.select { |name, action| name != "EXIT" && action.empty? }
        names.each do |name|
          next if name == "EXIT" || RUBY_RESERVED_SIGNALS.include?(name)
          Signal.trap(name, @traps[name] == "" ? "IGNORE" : "DEFAULT")
        end
        @pending_signals = []
        @saved_signals = nil
        @jobs = {}
        @active_streams = []
        @last_background_pid = nil
        @job_child = true
        @owned_job_group = job_group
        @options.delete("monitor")
        @replace_process = !@hosted
        @loop_depth = 0
        @function_depth = 0
        @process_substitutions = nil
      end
    end
  end
end
