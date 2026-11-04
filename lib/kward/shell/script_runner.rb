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
        runtime = Runtime.new(arguments: args, name: name, replace_process: true)
        unless options.empty?
          status = runtime.run("set #{Shellwords.join(options)}", input: input, output: output, error: error)
          return status unless status.zero?
        end
        if command
          runtime.run(command, input: input, output: output, error: error)
        elsif file
          File.open(file) { |source| runtime.run_input(source, input: input, output: output, error: error) }
        else
          runtime.run_input(input, input: input, output: output, error: error)
        end
        runtime.finish(input: input, output: output, error: error)
      rescue ArgumentError, SystemCallError => e
        error.puts("kwsh: #{e.message}")
        2
      end
    end
  end
end
