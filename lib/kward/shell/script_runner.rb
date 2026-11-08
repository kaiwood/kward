require_relative "native_runtime"
require_relative "native_vi_terminal"

module Kward
  module NativeShell
    # Standalone entrypoint: no agent, UI, auth, plugins, or implicit system shell.
    module ScriptRunner
      module_function

      def run(arguments, input: $stdin, output: $stdout, error: $stderr, name: nil, descriptors: {}, own_descriptors: false, hosted: false)
        args = arguments.dup
        options = []
        mode = nil
        interactive = false
        while args.first&.start_with?("-", "+") && args.first != "-"
          option = args.shift
          break if option == "--"
          if option == "--help"
            output.puts("Usage: kwsh [-i] [shell-options] [-c command [name [args...]] | -s [args...] | file [args...]]")
            return 0
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
        name ||= command_name || file || $0
        interactive ||= !hosted && !command && !file && input.tty? && error.tty?
        runtime = Runtime.new(arguments: args, name: name, replace_process: !hosted,
                              interactive: interactive || hosted, hosted: hosted, descriptors: descriptors, own_descriptors: own_descriptors)
        runtime.send(:reset_child_state, job_group: Process.getpgrp) if hosted
        runtime.with_signals do
          unless options.empty?
            status = runtime.run("set #{Shellwords.join(options)}", input: input, output: output, error: error)
            return status unless status.zero?
          end
          load_startup(runtime, input: input, output: output, error: error) if interactive
          unless runtime.exited
            if command
              runtime.run(command, input: input, output: output, error: error)
            elsif file
              File.open(file) do |source|
                if interactive
                  run_interactive(runtime, source, input: input, output: output, error: error)
                else
                  runtime.run_input(source, input: input, output: output, error: error)
                end
              end
            elsif interactive
              run_interactive(runtime, input, input: input, output: output, error: error)
            else
              runtime.run_input(input, input: input, output: output, error: error)
            end
          end
          runtime.send(:wait_builtin, [], { 0 => input, 1 => output, 2 => error }.merge(descriptors)) if hosted
          runtime.finish(input: input, output: output, error: error)
        end
      rescue ArgumentError, SystemCallError => e
        error.puts("kwsh: #{e.message}")
        2
      ensure
        runtime&.send(:close_resources)
        descriptors.values.compact.uniq.each { |io| io.close unless io.closed? } if own_descriptors
      end

      def load_startup(runtime, input:, output:, error:)
        return unless Process.uid == Process.euid && Process.gid == Process.egid
        path = runtime.expand_parameters(runtime.variables.fetch("ENV", ""))
        return if path.empty? || !File.file?(File.expand_path(path, runtime.cwd))
        runtime.run(". #{Shellwords.escape(path)}", input: input, output: output, error: error)
      rescue ExpansionError, ExecutionError => e
        error.puts("kwsh: ENV: #{e.message}")
      end

      def run_interactive(runtime, source_input, input:, output:, error:)
        source = +"".b
        runtime.with_signals do
          until runtime.exited
            begin
              line = runtime.with_prompt_input do
                runtime.notify_jobs(error: error, force: source.empty?)
                prompt = source.empty? ? "PS1" : "PS2"
                runtime.check_mail(error) if source.empty?
                text = runtime.prompt_text(prompt, error: error)
                if source_input.tty? && error.tty? && runtime.option_enabled?("vi")
                  editor ||= ViTerminal.new(runtime)
                  editor.read(source_input, prompt: text, input: input, output: output, error: error)
                else
                  error.write(text)
                  error.flush
                  read_line(source_input, runtime, input: input, output: output, error: error)
                end
              end
              edited = false
              if line.is_a?(ViEditor::Result)
                if line.external
                  edited = true
                  line = runtime.vi_edit(line.text, input: input, output: output, error: error)
                  unless line
                    source.clear
                    next
                  end
                else
                  line = line.text
                end
              end
              unless line
                if source_input.tty? && runtime.option_enabled?("ignoreeof") && !runtime.exited
                  error.puts("kwsh: use exit to leave the shell")
                  next
                end
                runtime.run(source, input: input, output: output, error: error) unless source.empty? || runtime.exited
                break
              end
              source << line
              text = source.dup.force_encoding(Encoding::UTF_8)
              text.force_encoding(Encoding::BINARY) unless text.valid_encoding?
              begin
                Parser.parse(text, aliases: runtime.aliases, eof: edited)
              rescue IncompleteInput
                next
              rescue SyntaxError
                # Runtime owns the diagnostic, status, and interactive recovery.
              end
              runtime.with_history_entry(text) do
                runtime.run(text, input: input, output: output, error: error)
              end
              source.clear
            rescue Interrupt
              runtime.interrupt_input
              source.clear
              error.puts
            end
          end
        end
      end

      def read_line(source, runtime, input:, output:, error:)
        line = +"".b
        loop do
          if source.is_a?(IO) && !IO.select([source], nil, nil, 0.1)
            runtime.poll_signals(input: input, output: output, error: error)
            runtime.notify_jobs(error: error)
            return nil if runtime.exited
            next
          end
          byte = source.readpartial(1)
          line << byte
          return line if byte == "\n"
        end
      rescue EOFError
        return line unless line.empty?
        return unless runtime.option_enabled?("ignoreeof") && !source.tty? && !runtime.exited
        # A FIFO may acquire another writer, or a file may grow. Keep the
        # interactive option's meaning without repeatedly printing prompts.
        sleep 0.1
        runtime.poll_signals(input: input, output: output, error: error)
        runtime.notify_jobs(error: error)
        retry unless runtime.exited
        nil
      end
    end
  end
end
