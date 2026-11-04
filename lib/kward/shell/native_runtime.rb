require "shellwords"
require "set"
require "tempfile"
require_relative "native_syntax"
require_relative "native_process"
require_relative "native_expansion"
require_relative "native_substitution"
require_relative "native_builtins"
require_relative "native_arrays"
require_relative "native_jobs"
require_relative "native_traps"
require_relative "native_program"

module Kward
  module NativeShell
    class ExecutionError < StandardError; end

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
      include Condition
      include Arrays
      include Jobs
      include Traps

      UNSUPPORTED = %w[local typeset ulimit builtin source].freeze
      SPECIAL = %w[export readonly eval . unset exit return break continue shift set exec trap :].freeze
      BUILTINS = (SPECIAL + %w[true false cd pwd alias unalias read getopts command shopt declare umask kwsh jobs fg bg wait kill]).freeze

      attr_reader :cwd, :variables, :aliases, :status, :exited

      def initialize(cwd: Dir.pwd, env: ENV.to_h, aliases: {}, arguments: [], name: "kwsh", interactive: false, replace_process: false, descriptors: {})
        @cwd = File.expand_path(cwd)
        @variables = env.dup
        @variables["PWD"] = @cwd
        @exported = Set.new(@variables.keys)
        @variables["IFS"] = Fields::DEFAULT_IFS
        @variables["LINENO"] = "1"
        @line_tracking = true
        @aliases = aliases.dup
        @arguments = arguments
        @name = name
        @shell_pid = Process.pid
        @functions = {}
        @arrays = {}
        @readonly = Set.new
        @source_depth = 0
        @eval_depth = 0
        @globstar = false
        @options = Set.new(interactive ? ["monitor"] : [])
        @jobs = {}
        @traps = {}
        @pending_signals = []
        @persistent_descriptors = descriptors.dup
        @owned_descriptors = []
        @active_streams = []
        @replace_process = replace_process
        @interactive = interactive
        @umask = File.umask
        @status = 0
        @exited = false
        @loop_depth = 0
        @function_depth = 0
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
        Program.each(input, aliases: @aliases) do |tree|
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
          0
        end
        failed_command = %i[simple subshell test arithmetic redirect].include?(node.kind) ||
                         node.kind == :pipeline && node.values.first.length > 1
        negated = node.kind == :pipeline && node.values.last
        raise Flow.new(:exit, @status) if failed_command && !negated && @options.include?("errexit") && !@ignore_failure && !@status.zero?
        run_pending_traps(streams)
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
            wait_builtin([], selected) if @interactive && !@jobs.empty?
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
        arguments = words.each_with_index.flat_map do |word, index|
          declaration = %w[export readonly].include?(words.first&.literal) && index.positive? && word.assignment
          expand(word, assignment: !!declaration)
        end
        persistent = SPECIAL.include?(arguments.first)
        with_redirects(redirects, streams, fatal: persistent) do |redirected|
          redirected[2]&.puts("+ #{Shellwords.join(arguments)}") if @options.include?("xtrace") && !arguments.empty?
          if arguments.empty?
            assigning = true
            assignments.each { |key, value| assign(key, expand(value, assignment: true).join) }
            next @substitution_status || 0
          end
          raise ExecutionError, "array prefix assignments require an assignment-only command" if assignments.any? { |key, _| key.is_a?(Reference) || @arrays.key?(key) }
          name = arguments.first
          saved = assignments.to_h { |key, _| [key, [@variables[key], @exported.include?(key)]] }
          begin
            assigning = true
            assignments.each do |key, value|
              assign(key, expand(value, assignment: true).join)
              @exported.add(key) if !persistent || name == "exec"
            end
            assigning = false
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
          raise ExecutionError, "pwd: expected -L or -P" unless args.empty? || args.all? { |option| %w[-L -P].include?(option) }
          write_line(streams, args.last == "-P" ? File.realpath(@cwd) : @cwd)
          0
        when "export" then export(args, streams)
        when "read" then read_variables(args, streams)
        when "readonly" then readonly(args, streams)
        when "declare" then declare_array(args)
        when "umask" then umask_builtin(args, streams)
        when "shopt" then shopt(args, streams)
        when "command" then command_builtin(args, streams)
        when "getopts" then getopts(args, streams)
        when "jobs" then jobs_builtin(args, streams)
        when "wait" then wait_builtin(args, streams)
        when "fg" then resume_job(args, streams, foreground: true)
        when "bg" then resume_job(args, streams, foreground: false)
        when "kill" then kill_builtin(args, streams)
        when "trap" then trap_builtin(args, streams)
        when "exec" then exec_builtin(args, streams)
        when "." then source_script(args, streams)
        when "eval"
          raise ExecutionError, "eval nesting exceeds 100 levels" if @eval_depth >= 100
          @eval_depth += 1
          begin
            evaluate_program(StringIO.new(args.join(" ")), streams)
          ensure
            @eval_depth -= 1
          end
        when "unset"
          functions_only = args.first == "-f"
          args.shift if %w[-f -v].include?(args.first)
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
              @arrays.delete(key)
              @exported.delete(key)
            end
          end
          0
        when "alias" then alias_command(args, streams)
        when "unalias"
          args == ["-a"] ? @aliases.clear : args.each { |name_to_remove| @aliases.delete(name_to_remove) }
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
        path = File.expand_path(args.first, @cwd)
        source = File.read(path)
        streams.values.compact.uniq.each(&:flush)
        pid = Process.fork do
          Signal.trap("INT", "DEFAULT")
          File.umask(@umask)
          runtime = self.class.new(cwd: @cwd, env: environment, arguments: args.drop(1), name: args.first, interactive: @interactive)
          runtime.send(:reset_child_state, job_group: @owned_job_group)
          runtime.run(source, input: streams[0], output: streams[1], error: streams[2])
          runtime.send(:wait_builtin, [], streams) if @interactive
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

      def assign(key, value)
        return array_store(key, value) if key.is_a?(Reference)
        validate_name(key)
        raise ExecutionError, "#{key}: readonly variable" if @readonly.include?(key)
        @line_tracking = false if key == "LINENO"
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
        if args.empty? || args == ["-p"]
          environment.sort.each { |key, value| write_line(streams, "export #{key}=#{Shellwords.escape(value)}") }
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
        if args.empty?
          @aliases.sort.each { |key, value| write_line(streams, "alias #{key}=#{Shellwords.escape(value)}") }
        else
          args.each do |argument|
            key, value = argument.split("=", 2)
            unless key.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/)
              raise ExecutionError, "invalid alias name: #{key}"
            end
            if value
              @aliases[key] = value
            elsif @aliases.key?(key)
              write_line(streams, "alias #{key}=#{Shellwords.escape(@aliases[key])}")
            else
              raise ExecutionError, "alias: not found: #{key}"
            end
          end
        end
        0
      end

      def change_directory(args, streams)
        physical = false
        while %w[-L -P --].include?(args.first)
          option = args.shift
          break if option == "--"
          physical = option == "-P"
        end
        raise ExecutionError, "cd: too many arguments" if args.length > 1
        target = args.first || @variables["HOME"]
        target = @variables["OLDPWD"] if target == "-"
        raise ExecutionError, "cd: directory is not set" if target.to_s.empty?
        path = physical ? File.realpath(target, @cwd) : File.expand_path(target, @cwd)
        raise ExecutionError, "cd: no such directory: #{target}" unless File.directory?(path)
        raise ExecutionError, "cd: permission denied: #{target}" unless File.executable?(path)
        @variables["OLDPWD"] = @cwd
        @cwd = path
        @variables["PWD"] = @cwd
        @exported.merge(%w[PWD OLDPWD])
        write_line(streams, @cwd) if args.first == "-"
        0
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
            next if escaped == "\n"
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
          targets = expand(word)
          raise ExecutionError, "ambiguous redirection" unless targets.length == 1
          target = targets.first
          if %w[>& <&].include?(operator)
            raise ExecutionError, "redirection requires descriptor 0 through 9, or -" unless target.match?(/\A[0-9-]\z/)
            raise ExecutionError, "bad file descriptor: #{target}" if target != "-" && !redirected[target.to_i]
            redirected[descriptor] = target == "-" ? nil : redirected[target.to_i]
          else
            mode = { "<" => "r", ">" => "w", ">|" => "w", ">>" => "a", "<>" => File::RDWR | File::CREAT }.fetch(operator)
            path = File.expand_path(target, @cwd)
            mode = File::WRONLY | File::CREAT | File::EXCL if operator == ">" && @options.include?("noclobber") && (!File.exist?(path) || File.file?(path))
            previous_mask = File.umask(@umask)
            begin
              file = File.open(path, mode)
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
          File.expand_path(name, @cwd)
        else
          candidates = @variables.fetch("PATH", "/usr/bin:/bin").split(":", -1).map do |directory|
            File.expand_path(File.join(directory.empty? ? "." : directory, name), @cwd)
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
        pid = NativeProcess.spawn(executable, arguments, environment, cwd: @cwd, streams: streams, mask: @umask, hosted: @interactive)
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
