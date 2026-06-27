require "open3"
require "shellwords"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Kward-native embedded shell command runner.
  class Ekwsh
    Result = Struct.new(:output, :exit_status, :exit_shell, :clear, keyword_init: true)

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

    private

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
