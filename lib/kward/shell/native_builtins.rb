module Kward
  module NativeShell
    # State-changing utilities execute in the interpreter, never in an external
    # shell. Explicit eval and dot-sourcing use the same native parser.
    module Builtins
      private

      SHELL_OPTIONS = { "a" => "allexport", "b" => "notify", "h" => "hashall", "v" => "verbose", "m" => "monitor", "e" => "errexit", "f" => "noglob", "n" => "noexec", "u" => "nounset", "x" => "xtrace", "C" => "noclobber" }.freeze

      def builtin_flags(args, allowed, command)
        flags = []
        while args.first&.start_with?("-") && args.first != "-"
          option = args.shift
          break if option == "--"
          option[1..].each_char do |flag|
            raise ExecutionError, "#{command}: unsupported option -#{flag}" unless allowed.include?(flag)
            flags << flag
          end
        end
        flags
      end

      def times_builtin(args, streams)
        builtin_flags(args, "", "times")
        raise ExecutionError, "times: unexpected operand" unless args.empty?
        usage = Process.times
        [[usage.utime, usage.stime], [usage.cutime, usage.cstime]].each do |pair|
          write_line(streams, pair.map { |seconds| format("%dm%.6fs", seconds.to_i / 60, seconds % 60) }.join(" "))
        end
        0
      end

      def hash_builtin(args, streams)
        flags = builtin_flags(args, "r", "hash")
        @command_hash.clear if flags.include?("r")
        if args.empty?
          @command_hash.sort.each { |_, path| write_line(streams, path) } if flags.empty?
          return 0
        end
        result = 0
        args.each do |name|
          next if self.class::BUILTINS.include?(name) || @functions.key?(name)
          path = executable_path(name)
          if path && File.file?(path) && File.executable?(path)
            @command_hash[name] = path unless name.include?("/")
          else
            streams[2]&.puts("kwsh: hash: #{name}: not found")
            result = 1
          end
        end
        result
      end

      def remember_function_commands(tree)
        return unless tree.is_a?(Node)
        if tree.kind == :simple
          word = tree.values.first.find { |item| !item.assignment }
          name = word&.literal
          if name && !self.class::BUILTINS.include?(name) && !@functions.key?(name)
            path = executable_path(name)
            @command_hash[name] = path if path && File.file?(path) && File.executable?(path)
          end
        end
        tree.values.flatten.each { |child| remember_function_commands(child) if child.is_a?(Node) }
      end

      def persist_descriptors(redirected, streams)
        redirected.each do |descriptor, io|
          next if streams[descriptor].equal?(io)
          copy = io&.dup
          copy.sync = true if copy
          @owned_descriptors << copy if copy
          @persistent_descriptors[descriptor] = copy
          streams[descriptor] = copy
          @base_streams[descriptor] = copy if @base_streams
        end
        release_descriptors
      end

      def release_descriptors
        retained = @persistent_descriptors.values + @active_streams.flat_map(&:values)
        @owned_descriptors.delete_if do |io|
          next false if retained.include?(io)
          io.close unless io.closed?
          true
        end
      end

      def exec_builtin(args, streams)
        clear = false
        argv0 = nil
        login = false
        while args.first&.start_with?("-")
          option = args.shift
          break if option == "--"
          case option
          when "-c" then clear = true
          when "-l" then login = true
          when "-a"
            argv0 = args.shift || raise(ExecutionError, "exec: -a requires a name")
          else raise ExecutionError, "exec: unsupported option #{option}"
          end
        end
        if args.empty?
          persist_descriptors(streams, @streams)
          NativeProcess.redirect_standard_streams(@persistent_descriptors) if @replace_process
          return 0
        end
        recover = @replace_process && interactive_scope?
        persist_descriptors(streams, @streams) if recover
        executable = executable_path(args.first)
        unless executable
          streams[2]&.puts("kwsh: #{args.first}: command not found")
          if recover
            NativeProcess.redirect_standard_streams(@persistent_descriptors)
            raise Flow.new(:abort, 127)
          end
          raise Flow.new(:exit, 127) unless interactive_scope?
          return 127
        end
        arguments = args.dup
        arguments[0] = argv0 || arguments[0]
        arguments[0] = "-#{arguments[0]}" if login
        env = clear ? {} : environment
        NativeProcess.validate(arguments, env)
        if @replace_process
          result = NativeProcess.replace(executable, arguments, env, cwd: @directory, streams: streams, mask: @umask, signals: child_signal_dispositions, recover: recover)
          NativeProcess.redirect_standard_streams(@persistent_descriptors) if recover
          raise Flow.new(recover ? :abort : :exit, result)
        else
          pid = NativeProcess.spawn(executable, arguments, env, cwd: @directory, streams: streams, mask: @umask, hosted: @hosted, signals: child_signal_dispositions)
          result = wait(pid)
          pid = nil
          # The protocol worker must return its final state before exiting.
          @traps.delete("EXIT")
          raise Flow.new(:exit, result)
        end
      rescue Interrupt
        @traps.delete("EXIT")
        raise Flow.new(:exit, 130)
      ensure
        terminate(pid) if pid
      end

      def set_options(args, streams)
        if args.empty?
          @variables.sort.each { |name, value| write_line(streams, "#{name}=#{Shellwords.escape(value)}") }
          return 0
        end
        until args.empty?
          option = args.shift
          if option == "-"
            @options.subtract(%w[verbose xtrace])
            @arguments = args unless args.empty?
            return 0
          end
          if option == "--"
            @arguments = args
            return 0
          end
          unless option.start_with?("-", "+") && option.length > 1
            @arguments = [option] + args
            return 0
          end
          enabled = option.start_with?("-")
          flags = option[1..].chars
          flags.each do |flag|
            name = if flag == "o"
              if args.empty?
                (SHELL_OPTIONS.values + ["pipefail"]).each do |entry|
                  write_line(streams, "set #{@options.include?(entry) ? '-' : '+'}o #{entry}")
                end
                next
              end
              args.shift
            else
              SHELL_OPTIONS[flag]
            end
            raise ExecutionError, "set: unsupported option #{name || flag}" unless (SHELL_OPTIONS.values + ["pipefail"]).include?(name)
            enabled ? @options.add(name) : @options.delete(name)
          end
        end
        0
      end

      def umask_builtin(args, streams)
        flags = builtin_flags(args, "S", "umask")
        if args.empty?
          text = unless flags.include?("S")
            format("%04o", @umask)
          else
            %w[u g o].each_with_index.map do |who, index|
              bits = (7 & ~(@umask >> (6 - index * 3)))
              permissions = [[4, "r"], [2, "w"], [1, "x"]].filter_map { |bit, letter| letter if bits & bit != 0 }.join
              "#{who}=#{permissions}"
            end.join(",")
          end
          write_line(streams, text)
          return 0
        end
        raise ExecutionError, "umask: expected one mask" unless args.length == 1
        value = args.first
        if value.match?(/\A[0-7]+\z/) && value.to_i(8) <= 0o777
          @umask = value.to_i(8)
          return 0
        end
        allowed = 0o777 & ~@umask
        executable = allowed & 0o111 != 0
        shifts = { "u" => 6, "g" => 3, "o" => 0 }
        value.split(",", -1).each do |clause|
          match = clause.match(/\A([ugoa]*)((?:[+=-](?:[ugo]|[rwxXst]*))+)\z/)
          raise ExecutionError, "umask: invalid symbolic mask" unless match
          who, actions = match.captures
          who = "ugo" if who.empty? || who.include?("a")
          actions.scan(/([+=-])([ugo]|[rwxXst]*)/).each do |operator, permissions|
            bits = if shifts.key?(permissions)
              (allowed >> shifts.fetch(permissions)) & 7
            else
              # Non-permission s/t bits do not affect the creation mask.
              permissions.chars.reduce(0) { |mask, letter| mask | { "r" => 4, "w" => 2, "x" => 1, "X" => executable ? 1 : 0 }.fetch(letter, 0) }
            end
            who.chars.uniq.each do |group|
              shift = shifts.fetch(group)
              allowed &= ~(7 << shift) if operator == "="
              allowed = operator == "-" ? allowed & ~(bits << shift) : allowed | (bits << shift)
            end
          end
        end
        @umask = 0o777 & ~allowed
        0
      end

      def source_script(args, streams)
        raise ExecutionError, ".: expected a file" if args.empty?
        raise ExecutionError, "source nesting exceeds 100 levels" if @source_depth >= 100
        name = args.first
        path = if name.include?("/")
          name
        else
          @variables.fetch("PATH", "/usr/bin:/bin").split(":", -1).map { |directory| @directory.resolve(File.join(directory.empty? ? "." : directory, name)) }.find { |candidate| File.file?(candidate) }
        end
        raise ExecutionError, ".: file not found: #{name}" unless path
        previous = @arguments
        @arguments = args.drop(1) if args.length > 1
        @source_depth += 1
        begin
          @directory.open_file(path) { |input| evaluate_program(input, streams) }
        rescue Flow => flow
          raise unless flow.kind == :return
          flow.status
        ensure
          @source_depth -= 1
          @arguments = previous
        end
      end

      def readonly(args, streams)
        flags = builtin_flags(args, "p", "readonly")
        if args.empty? || flags.include?("p")
          @readonly.sort.each do |name|
            value = @variables.key?(name) ? "=#{Shellwords.escape(parameter(name))}" : ""
            write_line(streams, "readonly #{name}#{value}")
          end
        else
          args.each do |argument|
            name, value = argument.split("=", 2)
            validate_name(name)
            assign(name, value) if value
            @readonly.add(name)
          end
        end
        0
      end

      def shopt(args, streams)
        mode = args.first&.start_with?("-") ? args.shift : nil
        raise ExecutionError, "shopt: supported options are -s, -u, and -q" unless [nil, "-s", "-u", "-q"].include?(mode)
        raise ExecutionError, "shopt: only globstar is currently supported" unless args.empty? || args == ["globstar"]
        case mode
        when "-s" then @globstar = true
        when "-u" then @globstar = false
        when "-q" then return @globstar ? 0 : 1
        else write_line(streams, "globstar\t#{@globstar ? 'on' : 'off'}")
        end
        0
      end

      def command_builtin(args, streams)
        flags = builtin_flags(args, "vVp", "command")
        mode = flags.reverse.find { |flag| %w[v V].include?(flag) }
        old_path = @variables["PATH"]
        saved_hash, saved_hash_path = @command_hash.dup, @hash_path
        @variables["PATH"] = Etc.confstr(Etc::CS_PATH) || "/usr/bin:/bin" if flags.include?("p")
        return 0 if args.empty?
        if mode
          result = 0
          args.each do |name|
            kind = if Parser::RESERVED.include?(name)
              "keyword"
            elsif self.class::SPECIAL.include?(name)
              "shell builtin"
            elsif @functions.key?(name)
              "function"
            elsif self.class::BUILTINS.include?(name)
              "shell builtin"
            end
            if @aliases.key?(name)
              write_line(streams, "alias #{name}=#{Shellwords.escape(@aliases[name])}")
              next
            end
            path = kind ? name : executable_path(name)
            path = nil if !kind && path && (!File.file?(path) || !File.executable?(path))
            if path
              write_line(streams, mode == "V" ? "#{name} is #{kind || path}" : path)
            else
              result = 1
            end
          end
          return result
        end
        dispatch(args, streams, functions: false)
      ensure
        if flags&.include?("p")
          old_path ? @variables["PATH"] = old_path : @variables.delete("PATH")
          @command_hash, @hash_path = saved_hash, saved_hash_path
        end
      end

      def getopts(args, streams)
        @getopts_running = true
        raise ExecutionError, "getopts: expected optstring and variable" if args.length < 2
        spec, name, *explicit = args
        validate_name(name)
        arguments = args.length > 2 ? explicit : @arguments
        index = Integer(@variables.fetch("OPTIND", "1"), 10)
        index = 1 if index < 1
        @getopts_offset = 1 if index != @getopts_index
        @getopts_offset ||= 1
        argument = arguments[index - 1]
        if !argument || !argument.start_with?("-") || argument == "-" || argument == "--"
          index += 1 if argument == "--"
          assign("OPTIND", index.to_s)
          assign(name, "?")
          @variables.delete("OPTARG")
          @getopts_index = index
          @getopts_offset = 1
          return 1
        end
        option = argument[@getopts_offset]
        @getopts_offset += 1
        position = spec.delete_prefix(":").index(option)
        silent = spec.start_with?(":")
        @variables.delete("OPTARG")
        if position.nil? || option == ":"
          assign(name, "?")
          assign("OPTARG", option) if silent
          streams[2]&.puts("getopts: illegal option -- #{option}") unless silent
        else
          assign(name, option)
          if spec.delete_prefix(":")[position + 1] == ":"
            value = argument[@getopts_offset..]
            if value.empty?
              value = arguments[index]
              index += 1 if value
            end
            if value
              assign("OPTARG", value)
            else
              assign(name, silent ? ":" : "?")
              assign("OPTARG", option) if silent
              streams[2]&.puts("getopts: option requires an argument -- #{option}") unless silent
            end
            @getopts_offset = argument.length
          end
        end
        if @getopts_offset >= argument.length
          index += 1
          @getopts_offset = 1
        end
        @getopts_index = index
        assign("OPTIND", index.to_s)
        0
      ensure
        @getopts_running = false
      end
    end
  end
end
