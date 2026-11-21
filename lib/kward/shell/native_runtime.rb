require "shellwords"
require "set"
require "tempfile"
require_relative "native_syntax"
require_relative "native_process"
require_relative "native_directory"
require_relative "native_expansion"
require_relative "native_substitution"
require_relative "native_builtins"
require_relative "native_history"
require_relative "native_interactive"
require_relative "native_arrays"
require_relative "native_jobs"
require_relative "native_traps"
require_relative "native_program"

module Kward
  module NativeShell
    class ExecutionError < StandardError; end
    class InvalidSignal < ExecutionError; end

    class Flow < StandardError
      attr_reader :kind, :status
      attr_accessor :levels

      def initialize(kind, status, levels: 1)
        @levels = levels
        @kind = kind
        @status = status
        super(kind.to_s)
      end
    end

    # Owns native shell state. External commands are always spawned with argv,
    # never a command string, and executable text has no implicit sh fallback.
    class Runtime
      include Expansion
      include Substitution
      include Builtins
      include HistoryCommands
      include Interactive
      include Condition
      include Arrays
      include Jobs
      include Traps

      UNSUPPORTED = %w[local typeset builtin].freeze
      SPECIAL = %w[export readonly eval . source unset exit return break continue shift set exec trap times :].freeze
      BUILTINS = (SPECIAL + %w[true false cd pwd alias unalias read getopts command shopt declare umask ulimit kwsh jobs fg bg wait kill hash type fc]).freeze

      attr_reader :variables, :aliases, :status, :exited

      def initialize(cwd: Dir.pwd, env: ENV.to_h, aliases: {}, arguments: [], name: "kwsh", interactive: false, replace_process: false, descriptors: {}, own_descriptors: false, hosted: interactive, directory: nil, process_owned: false)
        @directory = directory ? directory.dup : Directory.new(cwd)
        @cwd = File.expand_path(cwd)
        @cwd = initial_directory(env["PWD"]) unless hosted
        @variables = env.dup
        @variables["PWD"] = @cwd
        @exported = Set.new(@variables.keys)
        @variables["PPID"] = Process.ppid.to_s
        @variables["OPTIND"] = "1"
        @variables["IFS"] = Fields::DEFAULT_IFS
        @variables["LINENO"] = "1"
        @line_tracking = true
        @aliases = aliases.dup
        @arguments = arguments
        @name = name
        @shell_pid = Process.pid
        @process_owned = process_owned
        @functions = {}
        @command_hash = {}
        @arrays = {}
        @readonly = Set.new
        @source_depth = 0
        @eval_depth = 0
        @globstar = false
        @options = Set.new(interactive ? ["monitor"] : [])
        @jobs = {}
        @entry_ignored = Set.new(NativeProcess.ignored_signals.map { |name| Signal.list.key(Signal.list.fetch(name)) })
        @entry_ignored.subtract(%w[TSTP TTIN TTOU]) if hosted
        @traps = @entry_ignored.to_h { |name| [name, ""] }
        @pending_signals = []
        @persistent_descriptors = descriptors.dup
        @owned_descriptors = own_descriptors ? descriptors.values.compact.uniq : []
        @active_streams = []
        @replace_process = replace_process
        @interactive = interactive
        @hosted = hosted
        @umask = File.umask
        @status = 0
        @exited = false
        @loop_depth = 0
        @function_depth = 0
      end

      def cwd
        @directory.same?(@cwd) ? @cwd : @directory.physical_path
      rescue SystemCallError
        @cwd
      end

      def environment
        @variables.select { |key, _| @exported.include?(key) && !@arrays.key?(key) }
      end

      def run(source, input: $stdin, output: $stdout, error: $stderr)
        run_input(StringIO.new(source), input: input, output: output, error: error)
      end

      def run_input(source, input: $stdin, output: $stdout, error: $stderr)
        @base_streams = { 0 => input, 1 => output, 2 => error }.merge(@persistent_descriptors)
        with_signal_handlers { evaluate_program(source, @base_streams) }
      rescue Flow => flow
        if %i[exit abort].include?(flow.kind)
          @exited = true if flow.kind == :exit
          @status = flow.status
        else
          error&.puts("kwsh: #{flow.kind}: not in a valid context")
          @status = 2
        end
      rescue SyntaxError, ExpansionError, ExecutionError, SystemCallError, IOError, ArgumentError => e
        error&.puts("kwsh: #{e.message}")
        @exited = true unless interactive_scope?
        @status = 2
      rescue Interrupt
        @status = 130
      end

      # ENV and interactive prompts require parameter expansion, not evaluation
      # of arbitrary command text or command substitutions from the environment.
      def interrupt_input
        @status = 130
      end

      def expand_parameters(value)
        word = Lexer.new(value).heredoc_word
        validate_parameter_text(word)
        scalar(word)
      end

      def with_pager_suppressed
        previous = @variables["GIT_PAGER"]
        exported = @exported.include?("GIT_PAGER")
        @variables["GIT_PAGER"] = "cat"
        @exported.add("GIT_PAGER")
        yield
      ensure
        previous ? @variables["GIT_PAGER"] = previous : @variables.delete("GIT_PAGER")
        @exported.delete("GIT_PAGER") unless exported
      end

      private

      def close_resources
        @owned_descriptors.each { |io| io.close unless io.closed? }
        @owned_descriptors.clear
      ensure
        close_directory
      end

      def close_directory
        @directory.close
      end

      def initial_directory(inherited)
        # Validate against the runtime's directory, never the host process cwd.
        if inherited&.start_with?("/") && inherited.split("/").none? { |part| part == "." || part == ".." } && @directory.same?(inherited)
          return inherited
        end
        @directory.physical_path
      rescue SystemCallError
        # POSIX leaves PWD unspecified when the physical path cannot be found.
        @cwd
      end

      def validate_parameter_text(word)
        word.parts.each do |part|
          next if part.kind == :literal
          raise ExpansionError, "only parameter expansion is supported in ENV and prompts" unless part.kind == :parameter
          parameter = part.text
          if parameter.is_a?(Parameter)
            raise ExpansionError, "array references are not supported in ENV and prompts" unless parameter.name.is_a?(String)
            validate_parameter_text(parameter.word) if parameter.word
          elsif !parameter.is_a?(String)
            raise ExpansionError, "array references are not supported in ENV and prompts"
          end
        end
      end

      def interactive_scope?
        @interactive && !@job_child
      end

      def command_error(error, streams, fatal: false)
        streams[2]&.puts("kwsh: #{error.message}")
        raise Flow.new(interactive_scope? ? :abort : :exit, 2) if fatal
        2
      end

      def evaluate_program(input, streams)
        result = @status
        Program.each(input, aliases: @aliases, on_read: ->(byte) { streams[2]&.write(byte) if @options.include?("verbose") }) do |tree|
          result = evaluate(tree, streams) unless tree.values.first.empty?
        end
        @status = result
      end

      def evaluate(node, streams, ignored: false)
        @active_streams << streams
        previous_ignore = @ignore_failure
        previous_streams = @streams
        previous_description = @command_description
        @command_description = node.source if node.source
        @variables["LINENO"] = node.line.to_s if @line_tracking && node.line
        @ignore_failure = previous_ignore || ignored
        return 0 if @options.include?("noexec") && !@interactive
        @streams = streams
        @status = case node.kind
        when :background
          start_job(node.values.first, streams, background: true)
        when :sequence
          result = 0
          node.values.first.each { |command| result = evaluate(command, streams) }
          result
        when :and_or
          first, rest = node.values
          result = evaluate(first, streams, ignored: true)
          rest.each_with_index do |(operator, command), index|
            result = evaluate(command, streams, ignored: index < rest.length - 1) if operator == "&&" ? result.zero? : !result.zero?
          end
          result
        when :declare_array
          mode, name, words = node.values
          declare_array([mode, name])
          array_assignment(name, words)
        when :array_assign
          array_assignment(*node.values)
        when :test
          condition_value(node.values.first) ? 0 : 1
        when :arithmetic
          expression = node.values.first
          expression.strip.empty? || arithmetic_value(expression).to_i.zero? ? 1 : 0
        when :arithmetic_for
          (initial, condition, update), body = node.values
          arithmetic_value(initial) unless initial.strip.empty?
          loop_commands do
            result = 0
            while condition.strip.empty? || !arithmetic_value(condition).to_i.zero?
              result = loop_body(body, streams)
              arithmetic_value(update) unless update.strip.empty?
            end
            result
          end
        when :subshell
          subshell(node.values.first, streams)
        when :pipeline
          if @options.include?("monitor") && !@job_child && foreground_process?(node)
            start_job(node, streams, background: false)
          else
            pipeline(*node.values, streams)
          end
        when :simple
          simple(*node.values, streams)
        when :external
          external(node.values.first, streams)
        when :script
          script(node.values.first, streams)
        when :redirect
          command, redirects = node.values
          with_redirects(redirects, streams) { |redirected| evaluate(command, redirected) }
        when :if
          condition, yes, no = node.values
          evaluate(evaluate(condition, streams, ignored: true).zero? ? yes : no, streams)
        when :case
          subject, clauses = node.values
          value = scalar(subject)
          result = 0
          falling_through = false
          clauses.each do |patterns, body, fallthrough|
            next unless falling_through || patterns.any? { |word| matches_pattern?(pattern(word), value) }
            result = evaluate(body, streams)
            break unless fallthrough
            falling_through = true
          end
          result
        when :for
          name, words, body = node.values
          values = words ? words.flat_map { |word| expand(word) } : @arguments.dup
          loop_commands do
            result = 0
            values.each do |value|
              assign(name, value)
              result = loop_body(body, streams)
            end
            result
          end
        when :loop
          kind, condition, body = node.values
          loop_commands do
            result = 0
            while evaluate(condition, streams, ignored: true).zero? == (kind == "while")
              result = loop_body(body, streams)
            end
            result
          end
        when :function
          name, body = node.values
          @functions[name] = body
          remember_function_commands(body) if @options.include?("hashall")
          0
        end
        failed_command = %i[simple subshell test arithmetic redirect].include?(node.kind) ||
                         node.kind == :pipeline && node.values.first.length > 1
        negated = node.kind == :pipeline && node.values.last
        run_pending_traps(streams)
        raise Flow.new(:exit, @status) if failed_command && !negated && @options.include?("errexit") && !@ignore_failure && !@status.zero?
        @status
      ensure
        @streams = previous_streams
        @command_description = previous_description
        @ignore_failure = previous_ignore
        @active_streams.pop
        release_descriptors
      end

      def loop_commands
        @loop_depth += 1
        yield
      rescue Flow => flow
        raise unless flow.kind == :break
        flow.levels -= 1
        raise if flow.levels.positive?
        0
      ensure
        @loop_depth -= 1
      end

      def loop_body(body, streams)
        evaluate(body, streams)
      rescue Flow => flow
        raise unless flow.kind == :continue
        flow.levels -= 1
        raise if flow.levels.positive?
        0
      end

      def pipeline(commands, negate, streams)
        previous_ignore = @ignore_failure
        @ignore_failure ||= negate
        result = if commands.length == 1
          evaluate(commands.first, streams)
        else
          run_pipeline(commands, streams)
        end
        negate ? (result.zero? ? 1 : 0) : result
      ensure
        @ignore_failure = previous_ignore
      end

      def run_pipeline(commands, streams)
        streams.values.compact.uniq.each(&:flush)
        pipes = Array.new(commands.length - 1) { IO.pipe }
        pids = []
        commands.each_with_index do |command, index|
          pids << Process.fork do
            reset_child_state
            selected = streams.merge(
              0 => index.zero? ? streams[0] : pipes[index - 1][0],
              1 => index == commands.length - 1 ? streams[1] : pipes[index][1]
            )
            pipes.flatten.each { |io| io.close unless selected.value?(io) }
            begin
              exit_status = with_signal_handlers { evaluate(command, selected, ignored: index < commands.length - 1) }
            rescue Flow => flow
              exit_status = flow.status
            rescue StandardError => e
              selected[2]&.puts("kwsh: #{e.message}")
              exit_status = 2
            end
            wait_builtin([], selected) if @hosted && !@jobs.empty?
            @status = exit_status
            finish(input: selected[0], output: selected[1], error: selected[2])
            selected.values.compact.each { |io| io.flush rescue nil }
            exit!(@status)
          end
        end
        pipes.flatten.each(&:close)
        statuses = []
        until pids.empty?
          statuses << wait(pids.first)
          pids.shift
        end
        @options.include?("pipefail") ? statuses.reverse.find { |status| !status.zero? } || 0 : statuses.last
      ensure
        pipes&.flatten&.each { |io| io.close unless io.closed? }
        pids&.each { |pid| terminate(pid) }
      end

      def simple(words, redirects, streams)
        previous_substitutions = @process_substitutions
        @process_substitutions = []
        @substitution_status = nil
        assignments = []
        assigning = false
        words = words.dup
        assignments << words.shift.assignment while words.first&.assignment
        declaration_index = 0
        while words[declaration_index]&.literal == "command"
          declaration_index += 1
          declaration_index += 1 while words[declaration_index]&.literal&.match?(/\A(?:-p+|--)\z/)
        end
        declaration_utility = %w[export readonly].include?(words[declaration_index]&.literal)
        arguments = words.each_with_index.flat_map do |word, index|
          declaration = declaration_utility && index > declaration_index && word.assignment
          expand(word, assignment: !!declaration)
        end
        persistent = SPECIAL.include?(arguments.first)
        with_redirects(redirects, streams, fatal: persistent) do |redirected|
          if arguments.empty?
            assigning = true
            trace("", redirected) if assignments.empty?
            assignments.each { |key, value| assign_word(key, value, redirected) }
            next @substitution_status || 0
          end
          raise ExecutionError, "array prefix assignments require an assignment-only command" if assignments.any? { |key, _| key.is_a?(Reference) || @arrays.key?(key) }
          name = arguments.first
          saved = assignments.to_h { |key, _| [key, [@variables[key], @exported.include?(key)]] }
          begin
            assigning = true
            assignments.each do |key, value|
              assign_word(key, value, redirected)
              @exported.add(key) if !persistent || name == "exec"
            end
            assigning = false
            trace(Shellwords.join(arguments), redirected)
            dispatch(arguments, redirected)
          rescue ExecutionError, SystemCallError, IOError, ArgumentError => e
            command_error(e, redirected, fatal: assigning || persistent)
          ensure
            unless persistent
              saved.each do |key, (value, exported)|
                value ? @variables[key] = value : @variables.delete(key)
                exported ? @exported.add(key) : @exported.delete(key)
              end
            end
          end
        end
      rescue ExecutionError, SystemCallError, IOError, ArgumentError => e
        command_error(e, streams, fatal: assigning || persistent)
      ensure
        resources = @process_substitutions
        @process_substitutions = previous_substitutions
        finish_substitutions(resources) if resources
      end

      def dispatch(arguments, streams, functions: true)
        name, *args = arguments
        if functions && @functions.key?(name) && !SPECIAL.include?(name)
          return call_function(name, args, streams)
        end
        raise ExecutionError, "#{name}: not supported by native kwsh" if UNSUPPORTED.include?(name)

        case name
        when ":", "true" then 0
        when "false" then 1
        when "cd" then change_directory(args, streams)
        when "pwd"
          flags = builtin_flags(args, "LP", "pwd")
          raise ExecutionError, "pwd: unexpected operand" unless args.empty?
          logical = flags.last != "P" && @cwd.split("/").none? { |part| part == "." || part == ".." } && @directory.same?(@cwd)
          write_line(streams, logical ? @cwd : @directory.physical_path)
          0
        when "export" then export(args, streams)
        when "read" then read_variables(args, streams)
        when "readonly" then readonly(args, streams)
        when "declare" then declare_array(args)
        when "umask" then umask_builtin(args, streams)
        when "ulimit" then ulimit_builtin(args, streams)
        when "shopt" then shopt(args, streams)
        when "command" then command_builtin(args, streams)
        when "type"
          raise ExecutionError, "type: expected a name" if args.empty?
          command_builtin(["-V", "--", *args], streams)
        when "hash" then hash_builtin(args, streams)
        when "fc" then fc_builtin(args, streams)
        when "times" then times_builtin(args, streams)
        when "getopts" then getopts(args, streams)
        when "jobs" then jobs_builtin(args, streams)
        when "wait" then wait_builtin(args, streams)
        when "fg" then resume_job(args, streams, foreground: true)
        when "bg" then resume_job(args, streams, foreground: false)
        when "kill" then kill_builtin(args, streams)
        when "trap" then trap_builtin(args, streams)
        when "exec" then exec_builtin(args, streams)
        when ".", "source" then source_script(name, args, streams)
        when "eval"
          raise ExecutionError, "eval nesting exceeds 100 levels" if @eval_depth >= 100
          @eval_depth += 1
          begin
            evaluate_program(StringIO.new(args.join(" ")), streams)
          ensure
            @eval_depth -= 1
          end
        when "unset"
          flags = builtin_flags(args, "fv", "unset")
          raise ExecutionError, "unset: -f and -v are mutually exclusive" if flags.uniq.length > 1
          functions_only = flags.include?("f")
          args.each do |key|
            if !functions_only && (match = key.match(/\A([A-Za-z_][A-Za-z0-9_]*)\[(.*)\]\z/m))
              name, subscript = match.captures
              raise ExecutionError, "#{name}: readonly variable" if @readonly.include?(name)
              array = @arrays[name]
              next unless array
              if %w[@ *].include?(subscript) && !array.associative
                @arrays.delete(name)
              else
                reference = Reference.new(name: name, subscript: Word.new(parts: [Part.new(kind: :literal, text: subscript, quoted: true)]))
                array.values.delete(array_index(reference, array))
              end
              next
            end
            validate_name(key)
            if functions_only
              @functions.delete(key)
            else
              raise ExecutionError, "#{key}: readonly variable" if @readonly.include?(key)
              @variables.delete(key)
              @line_tracking = false if key == "LINENO"
              @command_hash.clear if key == "PATH"
              @arrays.delete(key)
              @exported.delete(key)
            end
          end
          0
        when "alias" then alias_command(args, streams)
        when "unalias"
          flags = builtin_flags(args, "a", "unalias")
          if flags.include?("a")
            @aliases.clear
          else
            raise ExecutionError, "unalias: expected an alias name" if args.empty?
            missing = args.reject { |name_to_remove| @aliases.delete(name_to_remove) }
            raise ExecutionError, "unalias: not found: #{missing.join(' ')}" unless missing.empty?
          end
          0
        when "set" then set_options(args, streams)
        when "shift"
          raise ExecutionError, "shift: expected one nonnegative count" if args.length > 1 || args.first && !args.first.match?(/\A\d+\z/)
          count = args.empty? ? 1 : args.first.to_i
          return 1 if count > @arguments.length
          @arguments = @arguments.drop(count)
          0
        when "break", "continue"
          raise ExecutionError, "#{name}: expected a positive count" if args.length > 1 || args.first && !args.first.match?(/\A[1-9][0-9]*\z/)
          levels = args.empty? ? 1 : [args.first.to_i, @loop_depth].min
          raise ExecutionError, "#{name}: not in a loop" if @loop_depth.zero?
          raise Flow.new(name.to_sym, 0, levels: levels)
        when "return", "exit"
          raise ExecutionError, "return: not in a function" if name == "return" && @function_depth.zero? && @source_depth.zero?
          raise ExecutionError, "#{name}: expected numeric status" if args.length > 1 || args.first && !args.first.match?(/\A[+-]?\d+\z/)
          raise Flow.new(name.to_sym, args.empty? ? @status : args.first.to_i % 256)
        when "kwsh" then script(args, streams)
        else external(arguments, streams)
        end
      end

      def call_function(name, args, streams)
        raise ExecutionError, "function nesting exceeds 100 levels" if @function_depth >= 100
        previous = @arguments
        @arguments = args
        @function_depth += 1
        begin
          evaluate(@functions.fetch(name), streams)
        rescue Flow => flow
          raise unless flow.kind == :return
          flow.status
        ensure
          @arguments = previous
          @function_depth -= 1
        end
      end

      def script(args, streams)
        if @options.include?("monitor") && !@job_child
          return start_job(Node.new(kind: :script, values: [args], source: @command_description), streams, background: false)
        end
        raise ExecutionError, "Usage: kwsh <file> [arguments...]" if args.empty?
        source = @directory.open_file(args.first, &:read)
        streams.values.compact.uniq.each(&:flush)
        pid = Process.fork do
          reset_child_state
          File.umask(@umask)
          runtime = self.class.new(cwd: cwd, directory: @directory, env: environment, arguments: args.drop(1), name: args.first,
                                   interactive: @hosted, hosted: @hosted, descriptors: streams.reject { |fd, _| fd < 3 }, process_owned: true)
          runtime.send(:reset_child_state, job_group: @owned_job_group)
          runtime.run(source, input: streams[0], output: streams[1], error: streams[2])
          runtime.send(:wait_builtin, [], streams) if @hosted
          status = runtime.finish(input: streams[0], output: streams[1], error: streams[2])
          streams.values.compact.uniq.each(&:flush)
          exit!(status)
        end
        result = wait(pid)
        pid = nil
        result
      ensure
        terminate(pid) if pid
      end

      def assign_word(key, word, streams)
        value = expand(word, assignment: true).join
        if @options.include?("xtrace") && key.is_a?(String)
          trace("#{key}=#{Shellwords.escape(value)}", streams)
        end
        assign(key, value)
      end

      def assign(key, value)
        return array_store(key, value) if key.is_a?(Reference)
        validate_name(key)
        raise ExecutionError, "#{key}: readonly variable" if @readonly.include?(key)
        @line_tracking = false if key == "LINENO"
        @command_hash.clear if key == "PATH"
        @getopts_index = nil if key == "OPTIND" && value == "1" && !@getopts_running
        @exported.add(key) if @options.include?("allexport")
        if @arrays.key?(key)
          array = @arrays[key]
          array.values[array.associative ? "0" : 0] = value
        else
          @variables[key] = value
        end
      end

      def validate_name(key)
        raise ExecutionError, "invalid variable name: #{key}" unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      end

      def export(args, streams)
        flags = builtin_flags(args, "p", "export")
        if args.empty? || flags.include?("p")
          @exported.sort.each do |key|
            value = @variables.key?(key) ? "=#{Shellwords.escape(@variables[key])}" : ""
            write_line(streams, "export #{key}#{value}")
          end
        else
          args.each do |argument|
            key, value = argument.split("=", 2)
            validate_name(key)
            assign(key, value) if value
            @exported.add(key)
          end
        end
        0
      end

      def alias_command(args, streams)
        builtin_flags(args, "", "alias")
        if args.empty?
          @aliases.sort.each { |key, value| write_line(streams, "#{key}=#{Shellwords.escape(value)}") }
        else
          args.each do |argument|
            key, value = argument.split("=", 2)
            unless key.match?(/\A[A-Za-z0-9_!%,@-]+\z/)
              raise ExecutionError, "invalid alias name: #{key}"
            end
            if value
              @aliases[key] = value
            elsif @aliases.key?(key)
              write_line(streams, "#{key}=#{Shellwords.escape(@aliases[key])}")
            else
              raise ExecutionError, "alias: not found: #{key}"
            end
          end
        end
        0
      end

      def change_directory(args, streams)
        flags = builtin_flags(args, "LPe", "cd")
        physical = flags.reverse.find { |flag| flag == "L" || flag == "P" } == "P"
        raise ExecutionError, "cd: too many arguments" if args.length > 1
        target = args.first || @variables["HOME"]
        target = @variables["OLDPWD"] if target == "-"
        raise ExecutionError, "cd: directory is not set" if target.to_s.empty?
        prefix = nil
        unless target.start_with?("/", "./", "../") || %w[. ..].include?(target) || args.first == "-"
          prefix = @variables.fetch("CDPATH", "").split(":", -1).find do |directory|
            candidate = @directory.resolve(File.join(directory.empty? ? "." : directory, target))
            File.directory?(candidate)
          end
        end
        target = File.join(prefix, target) if prefix && !prefix.empty?
        path = physical ? target : logical_directory(target)
        base = cwd
        operand = if !physical && path == base
          "."
        elsif !physical && path.start_with?(base.delete_suffix("/") + "/")
          path.delete_prefix(base.delete_suffix("/") + "/")
        else
          path
        end
        replacement = Directory.new(operand, base: @directory)
        status = 0
        if physical
          begin
            path = replacement.physical_path
          rescue SystemCallError => e
            # The descriptor is valid even when its physical name is unavailable.
            path = target.start_with?("/") ? target : File.join(cwd, target)
            if flags.include?("e")
              streams[2]&.puts("kwsh: cd: #{e.message}")
              status = 1
            end
          end
        end
        @variables["OLDPWD"] = @cwd
        previous = @directory
        @directory = replacement
        replacement = nil
        previous.close
        @cwd = path
        @variables["PWD"] = @cwd
        @exported.merge(%w[PWD OLDPWD])
        @command_hash.clear
        write_line(streams, @cwd) if args.first == "-" || prefix && !prefix.empty?
        status
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise ExecutionError, "cd: no such directory: #{target}"
      rescue Errno::EACCES
        raise ExecutionError, "cd: permission denied: #{target}"
      ensure
        replacement&.close
      end

      def logical_directory(target)
        path = target.start_with?("/") ? target : File.join(cwd, target)
        components = []
        path.split("/").each do |component|
          next if component.empty? || component == "."
          if component == ".."
            unless components.empty?
              preceding = "/#{components.join('/')}"
              raise ExecutionError, "cd: not a directory: #{preceding}" unless File.directory?(preceding)
              components.pop
            end
          else
            components << component
          end
        end
        "/#{components.join('/')}"
      end

      def read_variables(args, streams)
        raw = false
        delimiter = "\n"
        array_name = nil
        while args.first&.start_with?("-") && args.first != "-"
          option = args.shift
          break if option == "--"
          flags = option.delete_prefix("-")
          until flags.empty?
            flag = flags.slice!(0)
            case flag
            when "r" then raw = true
            when "a"
              array_name = flags.empty? ? args.shift : flags
              raise ExecutionError, "read: -a requires an array name" unless array_name
              flags = ""
            when "d"
              value = flags.empty? ? args.shift : flags
              raise ExecutionError, "read: -d requires a delimiter" unless value
              delimiter = value.empty? ? "\0" : value.byteslice(0, 1)
              flags = ""
            else raise ExecutionError, "read: unsupported option -#{flag}"
            end
          end
        end
        raise ExecutionError, "read: expected a variable name" if args.empty? && !array_name
        raise ExecutionError, "read: -a cannot be combined with variable operands" if array_name && !args.empty?
        validate_name(array_name) if array_name
        args.each { |name| validate_name(name) }
        input = streams[0]
        raise IOError, "standard input is closed" unless input
        text = +"".b
        complete = false
        while (byte = read_byte(input))
          if byte == delimiter
            complete = true
            break
          elsif byte == "\\" && !raw
            escaped = read_byte(input)
            break unless escaped
            if escaped == "\n"
              streams[2]&.write(prompt_text("PS2", error: streams[2])) if input.tty? && interactive_scope?
              next
            end
            text << byte << escaped
          else
            text << byte
          end
        end
        text.force_encoding(input.external_encoding || Encoding.default_external)
        characters = []
        source = text.each_char
        loop do
          character = source.next
          if character == "\\" && !raw
            characters.concat(Fields.characters(source.next, quoted: true))
          else
            characters.concat(Fields.characters(character, split: true))
          end
        end
        ranges = Fields.ranges(characters, ifs, limit: array_name ? nil : args.length - 1)
        if array_name
          declare_array(["-a", array_name])
          @arrays[array_name].values = ranges.each_with_index.to_h { |range, index| [index, Fields.value(characters[range])] }
        else
          args.each_with_index do |name, index|
            assign(name, ranges[index] ? Fields.value(characters[ranges[index]]) : "")
          end
        end
        complete ? 0 : 1
      end

      # Never read ahead: the next command may inherit this descriptor directly.
      def read_byte(input)
        input.readpartial(1)
      rescue EOFError
        nil
      end

      def write_line(streams, text)
        raise IOError, "standard output is closed" unless streams[1]
        streams[1].puts(text)
      end

      def with_redirects(redirects, streams, fatal: false)
        redirected = streams.dup
        opened = []
        redirects.each do |descriptor, operator, word|
          if word.is_a?(HereDocument)
            file = Tempfile.new("kwsh-heredoc")
            file.unlink
            opened << file
            file.write(scalar(word.word))
            file.rewind
            redirected[descriptor] = file
            next
          end
          # POSIX redirection words do not undergo field splitting or pathname
          # expansion (interactive pathname expansion is optional).
          target = scalar(word)
          if %w[>& <&].include?(operator)
            raise ExecutionError, "redirection requires descriptor 0 through 9, or -" unless target.match?(/\A[0-9-]\z/)
            raise ExecutionError, "bad file descriptor: #{target}" if target != "-" && !redirected[target.to_i]
            redirected[descriptor] = target == "-" ? nil : redirected[target.to_i]
          else
            mode = { "<" => "r", ">" => "w", ">|" => "w", ">>" => "a", "<>" => File::RDWR | File::CREAT }.fetch(operator)
            if operator == ">" && @options.include?("noclobber")
              path = @directory.resolve(target)
              mode = File::WRONLY | File::CREAT | File::EXCL if !File.exist?(path) || File.file?(path)
            end
            previous_mask = File.umask(@umask)
            begin
              file = @directory.open_file(target, mode)
            ensure
              File.umask(previous_mask)
            end
            file.sync = true
            opened << file
            redirected[descriptor] = file
          end
        end
        executing = true
        yield redirected
      rescue ExecutionError, SystemCallError, IOError, ArgumentError => e
        raise if executing
        command_error(e, redirected, fatal: fatal)
      ensure
        opened&.each(&:close)
      end

      def executable_path(name)
        if name.include?("/")
          @directory.resolve(name)
        else
          current_path = begin
            @directory.access_path
          rescue SystemCallError
            nil
          end
          path_key = [@variables["PATH"], current_path]
          if @hash_path != path_key
            @command_hash.clear
            @hash_path = path_key
          end
          cached = @command_hash[name]
          return cached if cached && File.file?(cached) && File.executable?(cached)
          @command_hash.delete(name)
          candidates = @variables.fetch("PATH", "/usr/bin:/bin").split(":", -1).filter_map do |directory|
            @directory.resolve(File.join(directory.empty? ? "." : directory, name))
          rescue Errno::ENOENT, Errno::EACCES
            nil
          end
          candidates.find { |path| File.file?(path) && File.executable?(path) } || candidates.find { |path| File.exist?(path) }
        end
      end

      def external(arguments, streams)
        if @options.include?("monitor") && !@job_child
          return start_job(Node.new(kind: :external, values: [arguments], source: @command_description), streams, background: false)
        end
        name = arguments.first
        executable = executable_path(name)
        unless executable
          streams[2]&.puts("kwsh: #{name}: command not found")
          return 127
        end
        pid = NativeProcess.spawn(executable, arguments, environment, cwd: @directory, streams: streams, mask: @umask, hosted: @hosted, signals: child_signal_dispositions)
        result = wait(pid)
        pid = nil
        result
      ensure
        terminate(pid) if pid
      end

      def wait(pid)
        loop do
          status = NativeProcess.wait(pid)
          if status.stopped?
            # Programs such as pagers can suspend themselves, not the entire
            # group. Surface that stop through the native job supervisor.
            Process.kill(status.stopsig, -@owned_job_group) if @owned_job_group == Process.getpgrp
            next
          end
          return status.exitstatus || 128 + status.termsig if status.exited? || status.signaled?
        end
      end

      def terminate(pid)
        Process.kill("TERM", pid)
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
