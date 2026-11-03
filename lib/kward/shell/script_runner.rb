require_relative "native_runtime"

module Kward
  module NativeShell
    # Standalone entrypoint: no agent, UI, auth, plugins, or implicit system shell.
    module ScriptRunner
      module_function

      def run(arguments, input: $stdin, output: $stdout, error: $stderr)
        args = arguments.dup
        options = []
        mode = nil
        while args.first&.start_with?("-", "+") && args.first != "-"
          option = args.shift
          break if option == "--"
          if option == "--help"
            output.puts("Usage: kwsh [shell-options] [-c command [name [args...]] | -s [args...] | file [args...]]")
            return 0
          elsif %w[-c -s].include?(option)
            mode = option
            break
          elsif %w[-o +o].include?(option)
            raise ArgumentError, "#{option} requires an option name" if args.empty?
            options.concat([option, args.shift])
          else
            options << option
          end
        end
        command = args.shift if mode == "-c"
        raise ArgumentError, "-c requires a command" if mode == "-c" && !command
        file = args.shift unless mode || args.empty? || args.first == "-"
        args.shift if !mode && !file && args.first == "-"
        name = mode == "-c" ? args.shift || "kwsh" : file || "kwsh"
        runtime = Runtime.new(arguments: args, name: name)
        unless options.empty?
          status = runtime.run("set #{Shellwords.join(options)}", input: input, output: output, error: error)
          return status unless status.zero?
        end
        if command || file
          runtime.run(command || File.read(file), input: input, output: output, error: error)
        else
          run_input(runtime, input, output, error)
        end
      rescue ArgumentError, SystemCallError => e
        error.puts("kwsh: #{e.message}")
        2
      end

      def run_input(runtime, input, output, error)
        source = +""
        status = 0
        loop do
          begin
            byte = input.readpartial(1)
          rescue EOFError
            return source.empty? ? status : runtime.run(source, input: input, output: output, error: error)
          end
          source << byte
          next unless byte == "\n"
          begin
            Parser.parse(source)
          rescue IncompleteInput
            next
          rescue SyntaxError
            return runtime.run(source, input: input, output: output, error: error)
          end
          status = runtime.run(source, input: input, output: output, error: error)
          return status if runtime.exited
          source = +""
        end
      end
      private_class_method :run_input
    end
  end
end
