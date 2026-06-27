require "open3"
require "shellwords"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Kward-native embedded shell command runner.
  class Ekwsh
    Result = Struct.new(:output, :exit_status, :exit_shell, :clear, :open_editor_path, keyword_init: true)
    Completion = Struct.new(:range, :replacement, :candidates, keyword_init: true)
    BUILTINS = %w[alias cd pwd export unset clear exit logout].freeze

    attr_reader :cwd

    def initialize(cwd: Dir.pwd, env: ENV.to_h, shell: ENV["SHELL"], configured_env: {}, aliases: {})
      @cwd = File.expand_path(cwd.to_s.empty? ? Dir.pwd : cwd.to_s)
      @previous_cwd = nil
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @env.merge!(configured_env.to_h.transform_keys(&:to_s).transform_values(&:to_s))
      @env["PWD"] = @cwd
      configure_rbenv_environment
      configure_color_environment
      @aliases = aliases.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @shell = shell.to_s.empty? ? "/bin/sh" : shell.to_s
    end

    def prompt_label
      "Shell #{display_cwd} $"
    end

    def run(input)
      command = input.to_s.strip
      return Result.new(output: "", exit_status: 0) if command.empty?
      return Result.new(output: command_echo(command), exit_status: 0, exit_shell: true) if exit_command?(command)

      builtin_result(command) || run_expanded_command(command)
    end

    def complete(input, cursor)
      token = completion_token(input.to_s, cursor.to_i)
      return nil if token[:command] && token[:text].empty?

      candidates = if token[:command] && !path_like_token?(token[:text])
                     command_candidates(token[:text])
                   else
                     path_candidates(token[:text], directories_only: cd_completion?(input, token))
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
      @env["TERM"] = "xterm-256color" if @env["TERM"].to_s.empty? || @env["TERM"] == "dumb"
    end

    def completion_token(input, cursor)
      cursor = [[cursor, 0].max, input.length].min
      start_index = cursor
      start_index -= 1 while start_index.positive? && token_character?(input, start_index - 1)
      text = input[start_index...cursor].to_s
      before = input[0...start_index].to_s
      { range: (start_index...cursor), text: text, command: before.strip.empty? }
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

    def command_candidates(prefix)
      (BUILTINS + @aliases.keys + path_executables).uniq.grep(/\A#{Regexp.escape(prefix)}/).sort
    end

    def path_executables
      @env.fetch("PATH", "").split(File::PATH_SEPARATOR).flat_map do |path|
        next [] unless File.directory?(path)

        Dir.children(path).filter_map do |entry|
          full_path = File.join(path, entry)
          entry if File.file?(full_path) && File.executable?(full_path)
        end
      rescue SystemCallError
        []
      end
    end

    def path_candidates(prefix, directories_only: false)
      raw_dir, raw_base = split_path_prefix(prefix)
      dir = File.expand_path(unescape_path(raw_dir.empty? ? "." : raw_dir), @cwd)
      return [] unless File.directory?(dir)

      Dir.children(dir).filter_map do |entry|
        next unless entry.start_with?(unescape_path(raw_base))

        path = File.join(dir, entry)
        directory = File.directory?(path)
        next if directories_only && !directory

        completed = "#{raw_dir}#{Shellwords.escape(entry)}"
        completed = "#{completed}/" if directory
        completed
      end.sort
    rescue SystemCallError
      []
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
      "$ #{command}\n"
    end

    def exit_command?(command)
      ["exit", "logout"].include?(command)
    end

    def builtin_result(command)
      words = shell_words(command)
      return nil if words.empty?

      case words.first
      when "alias"
        list_aliases(command, words)
      when "cd"
        change_directory(command, words)
      when "pwd"
        Result.new(output: "#{command_echo(command)}#{@cwd}\n", exit_status: 0)
      when "export"
        export_variables(command, words)
      when "unset"
        unset_variables(command, words)
      when "clear"
        Result.new(output: "", exit_status: 0, clear: true)
      else
        nil
      end
    rescue ArgumentError => e
      Result.new(output: "#{command_echo(command)}ekwsh: #{e.message}\n", exit_status: 2)
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
      lines = names.filter_map { |name| @aliases[name] ? "#{name}=#{Shellwords.escape(@aliases.fetch(name))}" : nil }
      suffix = lines.empty? ? "" : "#{lines.join("\n")}\n"
      Result.new(output: "#{command_echo(command)}#{suffix}", exit_status: 0)
    end

    def valid_alias_name?(name)
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

    def run_expanded_command(command)
      expanded_command = expand_alias(command)
      kward_result = kward_command_result(expanded_command, display_command: command)
      return kward_result if kward_result

      execute(expanded_command, display_command: command)
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

    def change_directory(command, words)
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
      if words.length == 1
        lines = @env.keys.sort.map { |key| "export #{key}=#{Shellwords.escape(@env.fetch(key))}" }
        return Result.new(output: "#{command_echo(command)}#{lines.join("\n")}\n", exit_status: 0)
      end

      invalid = []
      words.drop(1).each do |assignment|
        key, value = assignment.split("=", 2)
        if value.nil? || !valid_env_key?(key)
          invalid << assignment
        else
          @env[key] = value
        end
      end

      if invalid.empty?
        Result.new(output: command_echo(command), exit_status: 0)
      else
        Result.new(output: "#{command_echo(command)}ekwsh: export: invalid assignment: #{invalid.join(" ")}\n", exit_status: 2)
      end
    end

    def unset_variables(command, words)
      invalid = words.drop(1).reject { |key| valid_env_key?(key) }
      words.drop(1).each { |key| @env.delete(key) if valid_env_key?(key) }

      if invalid.empty?
        Result.new(output: command_echo(command), exit_status: 0)
      else
        Result.new(output: "#{command_echo(command)}ekwsh: unset: invalid name: #{invalid.join(" ")}\n", exit_status: 2)
      end
    end

    def valid_env_key?(key)
      key.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    def execute(command, display_command: command)
      stdout, stderr, status = Open3.capture3(@env, @shell, "-c", command, chdir: @cwd)
      exit_status = status.exitstatus || 1
      output = command_echo(display_command)
      output << clean_output(stdout)
      output << clean_output(stderr)
      output << "Exit status: #{exit_status}\n" unless exit_status.zero?
      Result.new(output: output, exit_status: exit_status)
    rescue Errno::ENOENT => e
      Result.new(output: "#{command_echo(display_command)}ekwsh: #{e.message}\n", exit_status: 127)
    end

    def clean_output(value)
      text = value.to_s.dup
      text.force_encoding(Encoding::UTF_8)
      text = text.valid_encoding? ? text : text.scrub
      text.end_with?("\n") || text.empty? ? text : "#{text}\n"
    end
  end
end
