module Kward
  module NativeShell
    Invocation = Struct.new(:options, :arguments, :file, :command, :command_name, :interactive, :help, keyword_init: true) do
      def self.parse(arguments)
        args = arguments.dup
        options = []
        mode = nil
        interactive = false
        while args.first&.start_with?("-", "+") && args.first != "-"
          option = args.shift
          break if option == "--"
          if option == "--help"
            return new(help: true)
          end
          option[1..].each_char do |flag|
            case flag
            when "c", "s"
              raise ArgumentError, "-c and -s are mutually exclusive" if mode && mode != flag
              raise ArgumentError, "+#{flag} is not supported" if option.start_with?("+")
              mode = flag
            when "i" then interactive = option.start_with?("-")
            when "o"
              raise ArgumentError, "#{option} requires an option name" if args.empty?
              options.concat(["#{option[0]}o", args.shift])
            else options << "#{option[0]}#{flag}"
            end
          end
        end
        args.shift if args.first == "-"
        command = args.shift if mode == "c"
        raise ArgumentError, "-c requires a command" if mode == "c" && !command
        file = args.shift unless mode || args.empty?
        command_name = args.shift if mode == "c"
        new(options: options, arguments: args, file: file, command: command, command_name: command_name, interactive: interactive)
      end

      def prompt?(input, error)
        !help && !command && !file && input.tty? && error.tty?
      end
    end
  end
end
