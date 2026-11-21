require_relative "native_completion"
require_relative "native_prompt_format"
require_relative "../terminal/ansi"

module Kward
  module NativeShell
    # Prompt-time state only. Hosted shells keep their composer and notifications.
    module Interactive
      class AgentCommandTimeout < StandardError; end

      def run_shell_agent_command(command, timeout:, output:, error:)
        require "timeout"
        @shell_agent_command = true
        previous = Signal.trap("INT") { raise Interrupt }
        File.open(File::NULL) do |input|
          Timeout.timeout(timeout, AgentCommandTimeout) do
            yield
            with_pager_suppressed { run(command, input: input, output: output, error: error) }
          end
        end
      rescue AgentCommandTimeout
        error.puts("kwsh: shell agent command timed out")
        @status = 124
      rescue Interrupt
        @status = 130
      ensure
        Signal.trap("INT", previous) if previous
        @shell_agent_command = false
      end

      def option_enabled?(name)
        @options.include?(name)
      end

      def complete_line(text, cursor)
        return if @hosted

        commands = self.class::BUILTINS + @aliases.keys + @functions.keys
        Completion.new(directory: @directory, variables: @variables, commands: commands).complete(text, cursor)
      end

      def vi_expansions(text, full:)
        previous_streams, previous_substitutions = @streams, @process_substitutions
        previous_status = @status
        @process_substitutions = []
        pattern = text.match?(/[*?\[]/) ? text : text + "*"
        @streams = @base_streams || { 0 => $stdin, 1 => $stdout, 2 => $stderr }
        matches = if full
          tokens = Lexer.new(pattern).tokens
          raise ExecutionError, "vi expansion requires one shell word" unless tokens.one? && tokens.first.value.is_a?(Word)
          expand(tokens.first.value)
        else
          Locale.with(@variables) { |locale| Glob.new(pattern, cwd: @directory, locale: locale, globstar: @globstar).matches }
        end
        matches.map { |path| File.directory?(@directory.resolve(path)) && !path.end_with?("/") ? path + "/" : path }
      ensure
        resources = @process_substitutions
        @streams, @process_substitutions = previous_streams, previous_substitutions
        @status = previous_status
        finish_substitutions(resources) if resources
      end

      def vi_input_error(exception, error:)
        @options.delete("vi")
        @status = 2
        error.puts("kwsh: vi disabled: #{exception.message}")
      end

      def vi_edit(source, input:, output:, error:)
        result, text = edit_history(source, "vi", { 0 => input, 1 => output, 2 => error }.merge(@persistent_descriptors))
        @status = result
        text if result.zero?
      rescue ExecutionError, SystemCallError, IOError, ArgumentError => e
        error.puts("kwsh: vi: #{e.message}")
        @status = 2
        nil
      end

      def prompt_text(name, error:, formatted: false)
        default = { "PS1" => "$ ", "PS2" => "> ", "PS4" => "+ " }.fetch(name)
        prefix = formatted && name != "PS4" && history.paused? ? "[private] " : ""
        if formatted && name == "PS1" && @variables.key?("PROMPT")
          color = error.tty? && @variables["TERM"] != "dumb" && ANSI.enabled?(error, env: @variables)
          return PromptFormat.new(@variables.fetch("PROMPT"), directory: cwd, home: @variables["HOME"], status: @status, color: color, prefix: prefix)
        end

        value = expand_parameters(@variables.fetch(name, default))
        value = value.gsub(/!!|!/) { |mark| mark == "!!" ? "!" : history.next_number.to_s } if name == "PS1" && !@hosted
        prefix + value
      rescue SyntaxError, ExpansionError, ExecutionError => e
        error&.puts("kwsh: #{name}: #{e.message}")
        prefix.to_s + default
      end

      def check_mail(error, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        return if @hosted
        @mail ||= MailNotifications.new
        @mail.check(@variables, @directory, now: now) do |message|
          error&.puts(expand_parameters(message))
        rescue SyntaxError, ExpansionError, ExecutionError => e
          error&.puts("kwsh: MAILPATH: #{e.message}")
        end
      end

      private

      def trace(text, streams)
        return unless @options.include?("xtrace")
        streams[2]&.puts("#{prompt_text('PS4', error: streams[2])}#{text}")
      end
    end

    class MailNotifications
      def initialize
        @seen = {}
      end

      def check(variables, directory, now:)
        interval = variables.fetch("MAILCHECK", "600")
        interval = interval.match?(/\A[0-9]+\z/) ? interval.to_i : 600
        return if @checked && now - @checked < interval
        @checked = now
        paths = variables.key?("MAILPATH") ? variables["MAILPATH"].split(":") : [variables["MAIL"]].compact
        current = {}
        paths.each do |entry|
          path, message = parse(entry)
          next if path.empty?
          key = nil
          begin
            key = directory.resolve(path)
            modified = File.stat(key).mtime
          rescue SystemCallError, IOError, ArgumentError
            key ||= path
            modified = nil
          end
          yield(message || "you have mail") if @seen.key?(key) && modified && modified != @seen[key]
          current[key] = modified
        end
        @seen = current
      end

      private

      def parse(entry)
        path = +""
        index = 0
        while index < entry.length
          if entry[index, 2] == '\\%'
            path << "%"
            index += 2
          elsif entry[index] == "%"
            return [path, entry[(index + 1)..]]
          else
            path << entry[index]
            index += 1
          end
        end
        [path, nil]
      end
    end
  end
end
