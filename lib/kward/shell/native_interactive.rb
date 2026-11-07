module Kward
  module NativeShell
    # Prompt-time state only. Hosted shells keep their composer and notifications.
    module Interactive
      def option_enabled?(name)
        @options.include?(name)
      end

      def prompt_text(name, error:)
        default = { "PS1" => "$ ", "PS2" => "> ", "PS4" => "+ " }.fetch(name)
        value = expand_parameters(@variables.fetch(name, default))
        value = value.gsub(/!!|!/) { |mark| mark == "!!" ? "!" : history.next_number.to_s } if name == "PS1" && !@hosted
        value
      rescue SyntaxError, ExpansionError, ExecutionError => e
        error&.puts("kwsh: #{name}: #{e.message}")
        default
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
