require "shellwords"
require_relative "ansi"
require_relative "local_command_runner"
begin
  require_relative "local_pty_command_runner"
rescue LoadError
  nil
end

# Namespace for the Kward CLI agent runtime.
module Kward
  # Kward-native embedded shell command runner.
  class Ekwsh
    Result = Struct.new(:output, :exit_status, :exit_shell, :clear, :open_editor_path, :interactive_command, :streamed, keyword_init: true)
    Completion = Struct.new(:range, :replacement, :candidates, keyword_init: true)
    BUILTINS = %w[alias cd pwd export unset unalias clear exit logout pty].freeze
    DEFAULT_SHELL = "/bin/sh"
    DEFAULT_TIMEOUT_SECONDS = 300
    DEFAULT_MAX_OUTPUT_BYTES = 1_048_576
    DEFAULT_HISTORY_LIMIT = 1_000

    attr_reader :cwd

    def command_shell
      @shell
    end

    def child_env(interactive: false)
      env = @env.dup
      env.delete("GIT_PAGER") if interactive && @defaulted_git_pager
      env
    end

    def initialize(cwd: Dir.pwd, env: ENV.to_h, shell: DEFAULT_SHELL, configured_env: {}, aliases: {}, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES)
      @cwd = File.expand_path(cwd.to_s.empty? ? Dir.pwd : cwd.to_s)
      @previous_cwd = nil
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @env.merge!(configured_env.to_h.transform_keys(&:to_s).transform_values(&:to_s))
      @env["PWD"] = @cwd
      configure_rbenv_environment
      configure_color_environment
      @aliases = aliases.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @shell = shell.to_s.empty? ? DEFAULT_SHELL : shell.to_s
      @timeout_seconds = timeout_seconds.to_i.positive? ? timeout_seconds.to_i : DEFAULT_TIMEOUT_SECONDS
      @max_output_bytes = max_output_bytes.to_i.positive? ? max_output_bytes.to_i : DEFAULT_MAX_OUTPUT_BYTES
    end

    def prompt_label
      "Shell #{display_cwd} $"
    end

    def run(input, cancellation: nil, &block)
      command = input.to_s.strip
      return Result.new(output: "", exit_status: 0) if command.empty?

      exit_result(command) || builtin_result(command) || run_expanded_command(command, cancellation: cancellation, &block)
    end

    def complete(input, cursor)
      token = completion_token(input.to_s, cursor.to_i)
      return nil if token[:command] && token[:text].empty?

      completion_text = token[:path_text] || token[:text]
      candidates = if token[:command] && !path_like_token?(completion_text) && !token[:quote]
                     command_candidates(completion_text)
                   else
                     path_candidates(completion_text, directories_only: cd_completion?(input, token), quote: token[:quote])
                   end
      return nil if candidates.empty?

      replacement = completion_replacement(token[:text], candidates)
      Completion.new(range: token[:range], replacement: replacement, candidates: candidates)
    end

    private

    def configure_rbenv_environment
      root = @env["RBENV_ROOT"].to_s
      root = File.expand_path("~/.rbenv") if root.empty?
      root = File.expand_path(root)
      paths = [File.join(root, "shims"), File.join(root, "bin")].select { |path| Dir.exist?(path) }
      return if paths.empty?

      @env["RBENV_ROOT"] = root
      @env["PATH"] = prepend_path_entries(@env["PATH"], paths)
    rescue ArgumentError
      nil
    end

    def prepend_path_entries(path, entries)
      current = path.to_s.split(File::PATH_SEPARATOR)
      (entries + current).uniq.join(File::PATH_SEPARATOR)
    end

    def configure_color_environment
      @env["CLICOLOR"] ||= "1"
      @env["COLORTERM"] ||= "truecolor"
      @defaulted_git_pager = !@env.key?("GIT_PAGER")
      @env["GIT_PAGER"] ||= "cat"
      @env["TERM"] = "xterm-256color" if @env["TERM"].to_s.empty? || @env["TERM"] == "dumb"
    end

    def completion_token(input, cursor)
      cursor = [[cursor, 0].max, input.length].min
      start_index = unmatched_quote_start(input[0...cursor]) || cursor
      start_index -= 1 while start_index.positive? && token_character?(input, start_index - 1)
      text = input[start_index...cursor].to_s
      before = input[0...start_index].to_s
      quote = quoted_completion_token(text)
      path_text = quote ? text[1..].to_s : nil
      { range: (start_index...cursor), text: text, path_text: path_text, quote: quote, command: before.strip.empty? }
    end

    def unmatched_quote_start(text)
      quote = nil
      quote_index = nil
      escaped = false
      text.to_s.each_char.with_index do |char, index|
        if escaped
          escaped = false
          next
        end
        if char == "\\" && quote != "'"
          escaped = true
          next
        end
        if quote
          quote = nil if char == quote
        elsif ["'", '"'].include?(char)
          quote = char
          quote_index = index
        end
      end
      quote ? quote_index : nil
    end

    def token_character?(input, index)
      return true unless input[index].match?(/\s/)

      escaped_character?(input, index)
    end

    def escaped_character?(input, index)
      backslashes = 0
      cursor = index - 1
      while cursor >= 0 && input[cursor] == "\\"
        backslashes += 1
        cursor -= 1
      end
      backslashes.odd?
    end

    def cd_completion?(input, token)
      input[0...token[:range].begin].to_s.strip == "cd"
    end

    def path_like_token?(text)
      text.to_s.include?("/")
    end

    def quoted_completion_token(text)
      quote = text.to_s[0]
      return nil unless ["'", '"'].include?(quote)
      return nil if text[1..].to_s.include?(quote)

      quote
    end

    def command_candidates(prefix)
      (BUILTINS + @aliases.keys + path_executables).uniq.grep(/\A#{Regexp.escape(prefix)}/).sort
    end

    def path_executables
      path = @env.fetch("PATH", "")
      return @path_executables_cache if @path_executables_cache_path == path && @path_executables_cache

      @path_executables_cache_path = path
      @path_executables_cache = path.split(File::PATH_SEPARATOR).flat_map do |path|
        next [] unless File.directory?(path)

        Dir.children(path).filter_map do |entry|
          full_path = File.join(path, entry)
          entry if File.file?(full_path) && File.executable?(full_path)
        end
      rescue SystemCallError
        []
      end
    end

    def invalidate_path_executables_cache
      @path_executables_cache_path = nil
      @path_executables_cache = nil
    end

    def path_candidates(prefix, directories_only: false, quote: nil)
      raw_dir, raw_base = split_path_prefix(prefix)
      dir = File.expand_path(unescape_path(raw_dir.empty? ? "." : raw_dir), @cwd)
      return [] unless File.directory?(dir)

      Dir.children(dir).filter_map do |entry|
        next unless entry.start_with?(unescape_path(raw_base))

        path = File.join(dir, entry)
        directory = File.directory?(path)
        next if directories_only && !directory

        completed = path_completion_candidate(raw_dir, entry, quote: quote)
        completed = "#{completed}/" if directory
        completed
      end.sort
    rescue SystemCallError
      []
    end

    def path_completion_candidate(raw_dir, entry, quote: nil)
      completed = "#{raw_dir}#{entry}"
      return "#{quote}#{completed.gsub(quote, "\\#{quote}")}" if quote

      "#{raw_dir}#{Shellwords.escape(entry)}"
    end

    def split_path_prefix(prefix)
      index = prefix.rindex("/")
      return ["", prefix] unless index

      [prefix[0..index], prefix[(index + 1)..].to_s]
    end

    def unescape_path(value)
      value.to_s.gsub(/\\(.)/, "\\1")
    end

    def completion_replacement(prefix, candidates)
      return add_completion_suffix(candidates.first) if candidates.length == 1

      common = common_prefix(candidates)
      common.length > prefix.length ? common : prefix
    end

    def add_completion_suffix(candidate)
      candidate.end_with?("/") ? candidate : "#{candidate} "
    end

    def common_prefix(values)
      first = values.first.to_s
      values.drop(1).reduce(first) do |prefix, value|
        prefix = prefix[0...-1] until value.start_with?(prefix) || prefix.empty?
        prefix
      end
    end

    def display_cwd
      home = Dir.home.to_s
      return "~" if @cwd == home
      return "~#{@cwd.delete_prefix(home)}" if !home.empty? && @cwd.start_with?("#{home}/")

      @cwd
    rescue ArgumentError
      @cwd
    end

    def command_echo(command)
      ANSI.sanitize_transcript("$ #{command}\n")
    end

    def exit_result(command)
      words = shell_words(command)
      return nil unless %w[exit logout].include?(words.first)

      if words.length > 2 || (words[1] && !words[1].match?(/\A\d+\z/))
        return Result.new(output: "#{command_echo(command)}ekwsh: #{words.first}: numeric status expected\n", exit_status: 2)
      end

      Result.new(output: command_echo(command), exit_status: words[1].to_i, exit_shell: true)
    rescue ArgumentError => e
      Result.new(output: "#{command_echo(command)}ekwsh: #{e.message}\n", exit_status: 2)
    end

    def builtin_result(command)
      words = shell_words(command)
      return nil if words.empty?
      assignment_result = persist_assignments(command, words)
      return assignment_result if assignment_result

      case words.first
      when "alias"
        list_aliases(command, words)
      when "unalias"
        remove_aliases(command, words)
      when "cd"
        change_directory(command, words)
      when "pwd"
        print_working_directory(command, words)
      when "export"
        export_variables(command, words)
      when "unset"
        unset_variables(command, words)
      when "clear"
        Result.new(output: "", exit_status: 0, clear: true)
      when "pty"
        interactive_pty_result(command)
      else
        nil
      end
    rescue ArgumentError => e
      Result.new(output: "#{command_echo(command)}ekwsh: #{e.message}\n", exit_status: 2)
    end

    def interactive_pty_result(command)
      interactive_command = command.sub(/\A\s*pty(?:\s+|\z)/, "")
      if interactive_command.empty?
        return Result.new(output: "#{command_echo(command)}Usage: pty <command>\n", exit_status: 2)
      end

      Result.new(output: "#{command_echo(command)}[interactive PTY session started]\n", exit_status: 0, interactive_command: interactive_command)
    end

    def shell_words(command)
      Shellwords.shellsplit(command)
    end

    def list_aliases(command, words)
      assignments, names = words.drop(1).partition { |word| word.include?("=") }
      invalid = []
      assignments.each do |assignment|
        name, value = assignment.split("=", 2)
        if valid_alias_name?(name)
          @aliases[name] = value.to_s
        else
          invalid << name
        end
      end
      return Result.new(output: "#{command_echo(command)}ekwsh: alias: invalid name: #{invalid.join(" ")}\n", exit_status: 2) unless invalid.empty?

      names = @aliases.keys.sort if names.empty? && assignments.empty?
      lines = names.filter_map { |name| @aliases[name] ? "alias #{name}=#{Shellwords.escape(@aliases.fetch(name))}" : nil }
      suffix = lines.empty? ? "" : "#{lines.join("\n")}\n"
      Result.new(output: "#{command_echo(command)}#{suffix}", exit_status: 0)
    end

    def remove_aliases(command, words)
      if words[1] == "-a" && words.length == 2
        @aliases.clear
        return Result.new(output: command_echo(command), exit_status: 0)
      end
      if words.length < 2 || words.drop(1).any? { |word| word.start_with?("-") }
        return Result.new(output: "#{command_echo(command)}Usage: unalias name ... | unalias -a\n", exit_status: 2)
      end

      missing = words.drop(1).reject { |name| @aliases.delete(name) }
      return Result.new(output: "#{command_echo(command)}ekwsh: unalias: not found: #{missing.join(" ")}\n", exit_status: 1) unless missing.empty?

      Result.new(output: command_echo(command), exit_status: 0)
    end

    def valid_alias_name?(name)
      self.class.valid_alias_name?(name)
    end

    def self.valid_alias_name?(name)
      name.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/) && !BUILTINS.include?(name.to_s)
    end

    def expand_alias(command)
      words = shell_words(command)
      return command if words.empty? || BUILTINS.include?(words.first)
      return command unless @aliases[words.first]

      rest = command.sub(/\A\s*#{Regexp.escape(words.first)}\b\s*/, "")
      [@aliases.fetch(words.first), rest].reject(&:empty?).join(" ")
    rescue ArgumentError
      command
    end

    def run_expanded_command(command, cancellation: nil, &block)
      expanded_command = expand_alias(command)
      kward_result = kward_command_result(expanded_command, display_command: command)
      return kward_result if kward_result

      execute(expanded_command, display_command: command, cancellation: cancellation, &block)
    end

    def kward_command_result(command, display_command: command)
      words = shell_words(command)
      return nil unless kward_edit_command?(words)

      unless words.length == 3
        return Result.new(output: "#{command_echo(display_command)}Usage: kward edit <filename>\n", exit_status: 2)
      end

      path = File.expand_path(words[2], @cwd)
      Result.new(output: command_echo(display_command), exit_status: 0, open_editor_path: path)
    rescue ArgumentError => e
      Result.new(output: "#{command_echo(display_command)}ekwsh: #{e.message}\n", exit_status: 2)
    end

    def kward_edit_command?(words)
      return false unless words[1] == "edit"

      File.basename(words[0].to_s) == "kward"
    end

    def persist_assignments(command, words)
      return nil unless words.all? { |word| assignment_word?(word) }

      words.each do |assignment|
        key, value = assignment.split("=", 2)
        set_env(key, value.to_s)
      end
      Result.new(output: command_echo(command), exit_status: 0)
    end

    def assignment_word?(word)
      key, value = word.to_s.split("=", 2)
      !value.nil? && valid_env_key?(key)
    end

    def print_working_directory(command, words)
      if words.length > 2 || (words[1] && !%w[-L -P].include?(words[1]))
        return Result.new(output: "#{command_echo(command)}Usage: pwd [-L|-P]\n", exit_status: 2)
      end

      Result.new(output: "#{command_echo(command)}#{@cwd}\n", exit_status: 0)
    end

    def change_directory(command, words)
      if words.length > 2
        return Result.new(output: "#{command_echo(command)}ekwsh: cd: too many arguments\n", exit_status: 2)
      end

      target = words[1]
      target = Dir.home if target.nil? || target.empty?
      target = @previous_cwd || @cwd if target == "-"
      path = File.expand_path(target, @cwd)
      unless File.directory?(path)
        return Result.new(output: "#{command_echo(command)}ekwsh: cd: no such directory: #{target}\n", exit_status: 1)
      end

      @previous_cwd = @cwd
      @cwd = path
      @env["OLDPWD"] = @previous_cwd
      @env["PWD"] = @cwd
      output = command_echo(command)
      output << "#{@cwd}\n" if words[1] == "-"
      Result.new(output: output, exit_status: 0)
    end

    def export_variables(command, words)
      if words.length == 1 || words == ["export", "-p"]
        lines = @env.keys.sort.map { |key| "export #{key}=#{Shellwords.escape(@env.fetch(key))}" }
        return Result.new(output: "#{command_echo(command)}#{lines.join("\n")}\n", exit_status: 0)
      end

      invalid = []
      words.drop(1).each do |assignment|
        key, value = assignment.split("=", 2)
        if !valid_env_key?(key) || assignment.start_with?("-")
          invalid << assignment
        else
          set_env(key, value.nil? ? "" : value)
        end
      end

      if invalid.empty?
        Result.new(output: command_echo(command), exit_status: 0)
      else
        Result.new(output: "#{command_echo(command)}ekwsh: export: invalid assignment: #{invalid.join(" ")}\n", exit_status: 2)
      end
    end

    def unset_variables(command, words)
      names = words.drop(1)
      names.shift if names.first == "--"
      invalid = names.select { |key| key.start_with?("-") || !valid_env_key?(key) }
      names.each { |key| delete_env(key) if valid_env_key?(key) }

      if invalid.empty?
        Result.new(output: command_echo(command), exit_status: 0)
      else
        Result.new(output: "#{command_echo(command)}ekwsh: unset: invalid name: #{invalid.join(" ")}\n", exit_status: 2)
      end
    end

    def set_env(key, value)
      @env[key] = value
      invalidate_path_executables_cache if key == "PATH"
    end

    def delete_env(key)
      @env.delete(key)
      invalidate_path_executables_cache if key == "PATH"
    end

    def valid_env_key?(key)
      key.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    def execute(command, display_command: command, cancellation: nil)
      output = command_echo(display_command)
      streamed = block_given?
      yield output.dup if streamed
      result = external_command_runner.new(
        timeout_seconds: @timeout_seconds,
        max_output_bytes: @max_output_bytes,
        terminate_on_output_limit: true
      ).run(@shell, "-c", command, env: @env, cwd: @cwd, cancellation: cancellation) do |_stream, chunk|
        text = clean_chunk(chunk)
        output << text
        yield text if streamed
      end
      append_output_newline(output) { |text| yield text if streamed }
      exit_status = result.timed_out || result.truncated ? 1 : (result.exit_status || 1)
      append_streamed(output, "ekwsh: command timed out after #{@timeout_seconds} seconds\n", streamed) { |text| yield text } if result.timed_out
      append_streamed(output, "ekwsh: output exceeded #{@max_output_bytes} bytes; command terminated\n", streamed) { |text| yield text } if result.truncated
      append_streamed(output, "Exit status: #{exit_status}\n", streamed) { |text| yield text } unless exit_status.zero?
      Result.new(output: output, exit_status: exit_status, streamed: streamed)
    rescue Cancellation::CancelledError
      append_output_newline(output) { |text| yield text if streamed }
      append_streamed(output, "^C\nExit status: 130\n", streamed) { |text| yield text }
      Result.new(output: output, exit_status: 130, streamed: streamed)
    rescue Errno::ENOENT => e
      Result.new(output: "#{command_echo(display_command)}ekwsh: #{e.message}\n", exit_status: 127)
    end

    def external_command_runner
      defined?(LocalPtyCommandRunner) ? LocalPtyCommandRunner : LocalCommandRunner
    end

    def append_streamed(output, text, streamed)
      output << text
      yield text if streamed && block_given?
    end

    def append_output_newline(output)
      return if output.end_with?("\n") || output.empty?

      output << "\n"
      yield "\n"
    end

    def clean_chunk(value)
      text = value.to_s.dup
      text.force_encoding(Encoding::UTF_8)
      text = text.valid_encoding? ? text : text.scrub
      ANSI.sanitize_transcript(text)
    end

    def clean_output(value)
      text = clean_chunk(value)
      text.end_with?("\n") || text.empty? ? text : "#{text}\n"
    end
  end
end
