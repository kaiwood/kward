require "open3"
require "shellwords"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Kward-native embedded shell command runner.
  class Ekwsh
    Result = Struct.new(:output, :exit_status, :exit_shell, :clear, keyword_init: true)
    Completion = Struct.new(:range, :replacement, :candidates, keyword_init: true)
    BUILTINS = %w[cd pwd export unset clear exit logout].freeze

    attr_reader :cwd

    def initialize(cwd: Dir.pwd, env: ENV.to_h, shell: ENV["SHELL"])
      @cwd = File.expand_path(cwd.to_s.empty? ? Dir.pwd : cwd.to_s)
      @previous_cwd = nil
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @env["PWD"] = @cwd
      @shell = shell.to_s.empty? ? "/bin/sh" : shell.to_s
    end

    def prompt_label
      "Shell #{display_cwd} $"
    end

    def run(input)
      command = input.to_s.strip
      return Result.new(output: "", exit_status: 0) if command.empty?
      return Result.new(output: command_echo(command), exit_status: 0, exit_shell: true) if exit_command?(command)

      builtin_result(command) || execute(command)
    end

    def complete(input, cursor)
      token = completion_token(input.to_s, cursor.to_i)
      return nil if token[:command] && token[:text].empty?

      candidates = token[:command] ? command_candidates(token[:text]) : path_candidates(token[:text], directories_only: cd_completion?(input, token))
      return nil if candidates.empty?

      replacement = completion_replacement(token[:text], candidates)
      Completion.new(range: token[:range], replacement: replacement, candidates: candidates)
    end

    private

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

    def command_candidates(prefix)
      (BUILTINS + path_executables).uniq.grep(/\A#{Regexp.escape(prefix)}/).sort
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

    def execute(command)
      stdout, stderr, status = Open3.capture3(@env, @shell, "-lc", command, chdir: @cwd)
      exit_status = status.exitstatus || 1
      output = command_echo(command)
      output << clean_output(stdout)
      output << clean_output(stderr)
      output << "Exit status: #{exit_status}\n" unless exit_status.zero?
      Result.new(output: output, exit_status: exit_status)
    rescue Errno::ENOENT => e
      Result.new(output: "#{command_echo(command)}ekwsh: #{e.message}\n", exit_status: 127)
    end

    def clean_output(value)
      text = value.to_s.dup
      text.force_encoding(Encoding::UTF_8)
      text = text.valid_encoding? ? text : text.scrub
      text.end_with?("\n") || text.empty? ? text : "#{text}\n"
    end
  end
end
