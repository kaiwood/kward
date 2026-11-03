require "shellwords"
require "set"
require_relative "native_syntax"
require_relative "native_process"

module Kward
  module NativeShell
    class ExecutionError < StandardError; end

    class Flow < StandardError
      attr_reader :kind, :status

      def initialize(kind, status)
        @kind = kind
        @status = status
        super(kind.to_s)
      end
    end

    # Owns native shell state. External commands are always spawned with argv,
    # never a command string, and executable text has no implicit sh fallback.
    class Runtime
      UNSUPPORTED = %w[eval exec trap readonly local typeset declare jobs fg bg wait read getopts umask ulimit command builtin source .].freeze
      SPECIAL = %w[export unset exit return break continue shift set :].freeze
      BUILTINS = (SPECIAL + %w[true false cd pwd alias unalias kwsh]).freeze
      DEFAULT_IFS = " \t\n".freeze

      attr_reader :cwd, :variables, :aliases, :status, :exited

      def initialize(cwd: Dir.pwd, env: ENV.to_h, aliases: {}, arguments: [], name: "kwsh")
        @cwd = File.expand_path(cwd)
        @variables = env.dup
        @variables["PWD"] = @cwd
        @exported = Set.new(@variables.keys)
        @aliases = aliases.dup
        @arguments = arguments
        @name = name
        @functions = {}
        @status = 0
        @exited = false
        @loop_depth = 0
        @function_depth = 0
        @alias_stack = []
      end

      def environment
        @variables.select { |key, _| @exported.include?(key) }
      end

      def run(source, input: $stdin, output: $stdout, error: $stderr)
        tree = Parser.parse(source)
        evaluate(tree, { 0 => input, 1 => output, 2 => error })
      rescue Flow => flow
        if flow.kind == :exit
          @exited = true
          @status = flow.status
        else
          error&.puts("kwsh: #{flow.kind}: not in a valid context")
          @status = 2
        end
      rescue SyntaxError, ExecutionError, SystemCallError, IOError, ArgumentError => e
        error&.puts("kwsh: #{e.message}")
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

      def evaluate(node, streams)
        @status = case node.kind
        when :sequence
          result = 0
          node.values.first.each { |command| result = evaluate(command, streams) }
          result
        when :and_or
          first, rest = node.values
          result = evaluate(first, streams)
          rest.each do |operator, command|
            result = evaluate(command, streams) if operator == "&&" ? result.zero? : !result.zero?
          end
          result
        when :pipeline
          pipeline(*node.values, streams)
        when :simple
          simple(*node.values, streams)
        when :redirect
          command, redirects = node.values
          with_redirects(redirects, streams) { |redirected| evaluate(command, redirected) }
        when :if
          condition, yes, no = node.values
          evaluate(evaluate(condition, streams).zero? ? yes : no, streams)
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
            while evaluate(condition, streams).zero? == (kind == "while")
              result = loop_body(body, streams)
            end
            result
          end
        when :function
          name, body = node.values
          @functions[name] = body
          0
        end
      end

      def loop_commands
        @loop_depth += 1
        yield
      rescue Flow => flow
        raise unless flow.kind == :break
        0
      ensure
        @loop_depth -= 1
      end

      def loop_body(body, streams)
        evaluate(body, streams)
      rescue Flow => flow
        raise unless flow.kind == :continue
        0
      end

      def pipeline(commands, negate, streams)
        result = if commands.length == 1
          evaluate(commands.first, streams)
        else
          run_pipeline(commands, streams)
        end
        negate ? (result.zero? ? 1 : 0) : result
      end

      def run_pipeline(commands, streams)
        streams.values.compact.uniq.each(&:flush)
        pipes = Array.new(commands.length - 1) { IO.pipe }
        pids = []
        commands.each_with_index do |command, index|
          pids << Process.fork do
            Signal.trap("INT", "DEFAULT")
            selected = streams.merge(
              0 => index.zero? ? streams[0] : pipes[index - 1][0],
              1 => index == commands.length - 1 ? streams[1] : pipes[index][1]
            )
            pipes.flatten.each { |io| io.close unless selected.value?(io) }
            begin
              exit_status = evaluate(command, selected)
            rescue Flow => flow
              exit_status = flow.status
            rescue StandardError => e
              selected[2]&.puts("kwsh: #{e.message}")
              exit_status = 2
            end
            selected.values.compact.each { |io| io.flush rescue nil }
            exit!(exit_status)
          end
        end
        pipes.flatten.each(&:close)
        result = 0
        until pids.empty?
          result = wait(pids.first)
          pids.shift
        end
        result
      ensure
        pipes&.flatten&.each { |io| io.close unless io.closed? }
        pids&.each { |pid| terminate(pid) }
      end

      def simple(words, redirects, streams)
        assignments = []
        words = words.dup
        assignments << words.shift.assignment while words.first&.assignment
        arguments = words.each_with_index.flat_map do |word, index|
          declaration = words.first&.literal == "export" && index.positive? && word.assignment
          expand(word, assignment: !!declaration)
        end
        with_redirects(redirects, streams) do |redirected|
          if arguments.empty?
            assignments.each { |key, value| assign(key, expand(value, assignment: true).join) }
            next 0
          end
          name = arguments.first
          persistent = SPECIAL.include?(name)
          saved = assignments.to_h { |key, _| [key, [@variables[key], @exported.include?(key)]] }
          begin
            assignments.each do |key, value|
              assign(key, expand(value, assignment: true).join)
              @exported.add(key) unless persistent
            end
            dispatch(arguments, redirected)
          rescue ExecutionError, SystemCallError, IOError, ArgumentError => e
            redirected[2]&.puts("kwsh: #{e.message}")
            2
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
        streams[2]&.puts("kwsh: #{e.message}")
        2
      end

      def dispatch(arguments, streams)
        name, *args = arguments
        if @functions.key?(name)
          return call_function(name, args, streams)
        end
        if @aliases.key?(name) && !BUILTINS.include?(name) && !@alias_stack.include?(name)
          raise ExecutionError, "alias expansion exceeds 100 levels" if @alias_stack.length >= 100
          @alias_stack << name
          begin
            return evaluate(Parser.parse([@aliases[name], *args.map { |arg| Shellwords.escape(arg) }].join(" ")), streams)
          ensure
            @alias_stack.pop
          end
        end
        raise ExecutionError, "#{name}: not supported by native kwsh" if UNSUPPORTED.include?(name)

        case name
        when ":", "true" then 0
        when "false" then 1
        when "cd" then change_directory(args, streams)
        when "pwd"
          raise ExecutionError, "pwd: arguments are not supported" unless args.empty?
          write_line(streams, @cwd)
          0
        when "export" then export(args, streams)
        when "unset"
          args.each { |key| validate_name(key); @variables.delete(key); @exported.delete(key) }
          0
        when "alias" then alias_command(args, streams)
        when "unalias"
          args == ["-a"] ? @aliases.clear : args.each { |name_to_remove| @aliases.delete(name_to_remove) }
          0
        when "set"
          raise ExecutionError, "set: only set -- <arguments> is supported" unless args.shift == "--"
          @arguments = args
          0
        when "shift"
          raise ExecutionError, "shift: expected one nonnegative count" if args.length > 1 || args.first && !args.first.match?(/\A\d+\z/)
          count = args.empty? ? 1 : args.first.to_i
          return 1 if count > @arguments.length
          @arguments = @arguments.drop(count)
          0
        when "break", "continue"
          raise ExecutionError, "#{name}: only the innermost loop is supported" unless args.empty? || args == ["1"]
          raise ExecutionError, "#{name}: not in a loop" if @loop_depth.zero?
          raise Flow.new(name.to_sym, 0)
        when "return", "exit"
          raise ExecutionError, "return: not in a function" if name == "return" && @function_depth.zero?
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
        raise ExecutionError, "Usage: kwsh <file> [arguments...]" if args.empty?
        path = File.expand_path(args.first, @cwd)
        source = File.read(path)
        streams.values.compact.uniq.each(&:flush)
        pid = Process.fork do
          Signal.trap("INT", "DEFAULT")
          runtime = self.class.new(cwd: @cwd, env: environment, arguments: args.drop(1), name: args.first)
          status = runtime.run(source, input: streams[0], output: streams[1], error: streams[2])
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
        validate_name(key)
        if key == "IFS" && value != DEFAULT_IFS
          raise ExecutionError, "custom IFS is not supported"
        end
        @variables[key] = value
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
            unless key.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/) && !BUILTINS.include?(key)
              raise ExecutionError, "invalid alias name: #{key}"
            end
            if value
              Parser.parse(value)
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
        raise ExecutionError, "cd: too many arguments" if args.length > 1
        target = args.first || @variables["HOME"]
        target = @variables["OLDPWD"] if target == "-"
        raise ExecutionError, "cd: directory is not set" if target.to_s.empty?
        path = File.expand_path(target, @cwd)
        raise ExecutionError, "cd: no such directory: #{target}" unless File.directory?(path)
        raise ExecutionError, "cd: permission denied: #{target}" unless File.executable?(path)
        @variables["OLDPWD"] = @cwd
        @cwd = path
        @variables["PWD"] = @cwd
        @exported.merge(%w[PWD OLDPWD])
        write_line(streams, @cwd) if args.first == "-"
        0
      end

      def write_line(streams, text)
        raise IOError, "standard output is closed" unless streams[1]
        streams[1].puts(text)
      end

      def parameter(name)
        case name
        when "?" then @status.to_s
        when "$" then Process.pid.to_s
        when "#" then @arguments.length.to_s
        when "@", "*" then @arguments.join(" ")
        when "0" then @name
        when /\A\d+\z/ then @arguments[name.to_i - 1].to_s
        else @variables.fetch(name, "")
        end
      end

      def arithmetic_value(expression)
        Arithmetic.evaluate(expression) { |name| parameter(name) }.to_s
      rescue Arithmetic::Error => e
        raise ExecutionError, e.message
      end

      # Each field carries both its value and a glob pattern. Quoted wildcard
      # characters are escaped only in the pattern, never in the argv value.
      def expand(word, assignment: false)
        fields = [[+"", +"", false]]
        word.parts.each_with_index do |part, index|
          if part.kind == :parameter && part.text == "@" && part.quoted && !assignment
            if @arguments.empty?
              # The synthetic empty quote does not turn an empty "$@" into an argument.
              fields.last[2] = false if word.parts.all? { |item| item.kind == :parameter && item.text == "@" || item.kind == :literal && item.text.empty? }
            else
              @arguments.each_with_index do |argument, argument_index|
                fields << [+"", +"", false] if argument_index.positive?
                append_field(fields.last, argument, true)
              end
            end
            next
          end
          value = case part.kind
          when :parameter then parameter(part.text)
          when :arithmetic then arithmetic_value(part.text)
          else part.text
          end
          if index.zero? && part.kind == :literal && !part.quoted && (value == "~" || value.start_with?("~/"))
            home = @variables.fetch("HOME", "~")
            append_field(fields.last, home, true)
            value = value.delete_prefix("~")
          elsif part.kind == :literal && !part.quoted && value.start_with?("~") && index.zero?
            raise ExecutionError, "named-user tilde expansion is not supported"
          end
          if part.kind == :parameter && !part.quoted && !assignment
            raise ExecutionError, "custom IFS is not supported" unless @variables.fetch("IFS", DEFAULT_IFS) == DEFAULT_IFS
            value.split(/([ \t\n]+)/).each do |piece|
              if piece.match?(/\A[ \t\n]+\z/)
                fields << [+"", +"", false] if fields.last[2]
              else
                append_field(fields.last, piece, false) unless piece.empty?
              end
            end
          else
            append_field(fields.last, value, part.quoted || assignment)
          end
        end
        return [fields.map(&:first).join] if assignment
        fields.select { |_, _, present| present }.flat_map do |value, pattern, _|
          raise ExecutionError, "recursive glob patterns are not supported" if pattern.match?(/(?<!\\\\)\*\*/)
          matches = pattern.match?(/[*?\[]/) ? Dir.glob(pattern, base: @cwd).sort : []
          matches.empty? ? [value] : matches
        end
      end

      def append_field(field, value, quoted)
        field[0] << value
        field[1] << (quoted ? value.gsub(/[\\*?\[\]{}]/) { |character| "\\#{character}" } : value.gsub(/[\\{}]/) { |character| "\\#{character}" })
        field[2] = true
      end

      def with_redirects(redirects, streams)
        redirected = streams.dup
        opened = []
        redirects.each do |descriptor, operator, word|
          targets = expand(word)
          raise ExecutionError, "ambiguous redirection" unless targets.length == 1
          target = targets.first
          if %w[>& <&].include?(operator)
            raise ExecutionError, "redirection requires descriptor 0, 1, 2, or -" unless target.match?(/\A[012-]\z/)
            redirected[descriptor] = target == "-" ? nil : redirected.fetch(target.to_i)
          else
            mode = { "<" => "r", ">" => "w", ">>" => "a" }.fetch(operator)
            file = File.open(File.expand_path(target, @cwd), mode)
            file.sync = true
            opened << file
            redirected[descriptor] = file
          end
        end
        yield redirected
      ensure
        opened&.each(&:close)
      end

      def external(arguments, streams)
        name = arguments.first
        executable = if name.include?("/")
          File.expand_path(name, @cwd)
        else
          candidates = @variables.fetch("PATH", "/usr/bin:/bin").split(":", -1).map do |directory|
            File.expand_path(File.join(directory.empty? ? "." : directory, name), @cwd)
          end
          candidates.find { |path| File.file?(path) && File.executable?(path) } || candidates.find { |path| File.exist?(path) }
        end
        unless executable
          streams[2]&.puts("kwsh: #{name}: command not found")
          return 127
        end
        pid = NativeProcess.spawn(executable, arguments, environment, cwd: @cwd, streams: streams)
        result = wait(pid)
        pid = nil
        result
      ensure
        terminate(pid) if pid
      end

      def wait(pid)
        _, status = Process.wait2(pid)
        status.exitstatus || 128 + status.termsig
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
