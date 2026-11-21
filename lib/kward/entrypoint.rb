module Kward
  # Select shell mode before loading the coding agent or parsing its options.
  module Entrypoint
    def self.run(arguments = ARGV, name: $PROGRAM_NAME)
      if arguments.first == "shell"
        require_relative "shell/native_process"
        NativeShell::NativeProcess.standalone(arguments.drop(1), name: "#{name} shell", program: "kward shell", edit_lines: true, load_rc: true)
      else
        require_relative "../kward"
        CLI.new(argv: arguments).run
      end
    end
  end
end
