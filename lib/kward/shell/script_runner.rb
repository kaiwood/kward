require_relative "native_runtime"
require_relative "native_invocation"
require_relative "native_vi_terminal"
require_relative "native_line_editor"
require_relative "kwshrc"

module Kward
  module NativeShell
    # Interpreter entrypoint. Optional shell-agent requests go to the launcher.
    module ScriptRunner
      module_function

      def run(arguments, input: $stdin, output: $stdout, error: $stderr, name: nil, descriptors: {}, own_descriptors: false, hosted: false, process_owned: false, program: "kwsh", edit_lines: false, load_rc: false, shell_link: nil)
        invocation = Invocation.parse(arguments)
        if invocation.help
          output.puts("Usage: #{program} [-i] [shell-options] [-c command [name [args...]] | -s [args...] | file [args...]]")
          return 0
        end
        options, args, file, command, command_name = invocation.deconstruct
        name ||= command_name || file || $0
        interactive = invocation.interactive || !hosted && invocation.prompt?(input, error)
        env = ENV.to_h
        runtime = Runtime.new(arguments: args, name: name, replace_process: !hosted, env: env,
                              interactive: interactive || hosted, hosted: hosted, descriptors: descriptors, own_descriptors: own_descriptors, process_owned: process_owned)
        runtime.send(:reset_child_state, job_group: Process.getpgrp) if hosted
        runtime.with_signals do
          unless options.empty?
            status = runtime.run("\\set #{Shellwords.join(options)}", input: input, output: output, error: error)
            return status unless status.zero?
          end
          if interactive
            load_kwshrc(runtime, input: input, output: output, error: error) if load_rc && !hosted
            load_startup(runtime, input: input, output: output, error: error, value: env.fetch("ENV", "")) unless runtime.exited
          end
          unless runtime.exited
            if command
              runtime.run(command, input: input, output: output, error: error)
            elsif file
              File.open(file) do |source|
                if interactive
                  run_interactive(runtime, source, input: input, output: output, error: error, edit_lines: edit_lines && !hosted)
                else
                  runtime.run_input(source, input: input, output: output, error: error)
                end
              end
            elsif interactive
              run_interactive(runtime, input, input: input, output: output, error: error, edit_lines: edit_lines && !hosted, shell_link: shell_link)
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

      def load_kwshrc(runtime, input:, output:, error:)
        return unless matching_identity?

        Kwshrc.paths.each do |path|
          break if runtime.exited
          next unless File.file?(path)

          runtime.run("\\. #{Shellwords.escape(path)}", input: input, output: output, error: error)
        end
      end

      def matching_identity?
        Process.uid == Process.euid && Process.gid == Process.egid
      end

      def load_startup(runtime, input:, output:, error:, value: runtime.variables.fetch("ENV", ""))
        return unless matching_identity?
        path = runtime.expand_parameters(value)
        return if path.empty? || !File.file?(File.expand_path(path, runtime.cwd))
        runtime.run("\\. #{Shellwords.escape(path)}", input: input, output: output, error: error)
      rescue ExpansionError, ExecutionError => e
        error.puts("kwsh: ENV: #{e.message}")
      end

      def run_interactive(runtime, source_input, input:, output:, error:, edit_lines:, shell_link: nil)
        source = +"".b
        draft = nil
        history_controls = edit_lines && source_input.tty? && error.tty?
        terminals = { vi: ViTerminal.new(runtime) }
        terminals[:line] = LineTerminal.new(runtime, LineEditor.new(runtime), bracketed_paste: true) if edit_lines
        runtime.with_signals do
          until runtime.exited
            begin
              line = runtime.with_prompt_input do
                runtime.notify_jobs(error: error, force: source.empty?)
                prompt = source.empty? ? "PS1" : "PS2"
                runtime.check_mail(error) if source.empty?
                text = runtime.prompt_text(prompt, error: error, formatted: edit_lines)
                read_prompt_line(runtime, source_input, terminals, prompt: text, input: input, output: output, error: error, draft: draft)
              end
              draft = nil
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
              if history_controls && source.empty? && handle_history_control(line, runtime.history, shell_link, output)
                next
              end
              if shell_link && source.empty? && line.start_with?("?")
                if runtime.history.paused?
                  error.puts("Shell agent unavailable while history is paused. Use history resume first.")
                  next
                end
                instruction = line.delete_prefix("?").strip
                if instruction.empty?
                  error.puts("Shell prompt instruction required after ?")
                else
                  draft = shell_link.ask(instruction, runtime, input: input, output: output, error: error) do
                    prompt = runtime.prompt_text("PS1", error: error, formatted: edit_lines)
                    render_plain_prompt(runtime, prompt, literal: true)
                  end
                end
                next
              end
              source << line
              text = source.dup.force_encoding(Encoding::UTF_8)
              text.force_encoding(Encoding::BINARY) unless text.valid_encoding?
              capture = shell_link && !runtime.history.paused? && !text.strip.empty?
              begin
                Parser.parse(text, aliases: runtime.aliases, eof: edited)
              rescue IncompleteInput
                next
              rescue SyntaxError
                # Runtime owns the diagnostic, status, and interactive recovery.
              end
              runtime.with_history_entry(text) do
                shell_link.begin_command(text, input: input) if capture
                runtime.run(text, input: input, output: output, error: error)
                shell_link.finish_command(runtime.status) if capture
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

      def handle_history_control(line, history, shell_link, output)
        case line.strip
        when "history pause"
          shell_link&.clear_context
          history.paused = true
        when "history resume"
          history.paused = false
        when "history status"
          output.puts(history.paused? ? "Shell history is paused." : "Shell history is recording.")
        else
          return false
        end
        true
      end

      def read_prompt_line(runtime, source, terminals, prompt:, input:, output:, error:, draft: nil)
        if source.tty? && error.tty? && runtime.variables["TERM"] != "dumb"
          style = runtime.option_enabled?("vi") ? :vi : :line
          if (terminal = terminals[style])
            begin
              return terminal.read(source, prompt: prompt, input: input, output: output, error: error, draft: draft)
            rescue ExecutionError, SystemCallError, IOError => e
              terminals.delete(style)
              error.puts("kwsh: line editing disabled: #{e.message}")
            end
          end
        end
        error.puts("Prepared shell command:\n#{draft}") if draft
        error.write(render_plain_prompt(runtime, prompt))
        error.flush
        read_line(source, runtime, input: input, output: output, error: error)
      end

      def render_plain_prompt(runtime, prompt, literal: false)
        return prompt unless literal || prompt.is_a?(PromptFormat)

        render = ->(locale) do
          if prompt.is_a?(PromptFormat)
            prompt.render(prompt.cells(locale.encoding))
          else
            TerminalText.locale_cells(prompt).map(&:first).join
          end
        end
        Locale.with(runtime.variables, &render)
      rescue ExecutionError
        Locale.with({}, &render)
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
