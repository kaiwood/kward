require "base64"
require "open3"
require "rbconfig"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Best-effort local clipboard writer used by explicit user copy commands.
  class Clipboard
    Result = Struct.new(:success?, :method, :message, keyword_init: true)

    def initialize(output: $stdout, env: ENV, command_runner: nil)
      @output = output
      @env = env
      @command_runner = command_runner || method(:run_command)
    end

    def copy(text)
      content = text.to_s
      return Result.new(success?: false, message: "nothing to copy") if content.empty?

      if osc52_available?
        write_osc52(content)
        return Result.new(success?: true, method: "osc52", message: "copied")
      end

      clipboard_commands.each do |name, command|
        next unless executable?(name)

        return Result.new(success?: true, method: name, message: "copied") if @command_runner.call(command, content)
      end

      Result.new(success?: false, message: "no supported clipboard mechanism found")
    end

    private

    def osc52_available?
      @output.respond_to?(:tty?) && @output.tty?
    end

    def write_osc52(content)
      encoded = Base64.strict_encode64(content)
      @output.print("\e]52;c;#{encoded}\a")
      @output.flush if @output.respond_to?(:flush)
    end

    def clipboard_commands
      if windows?
        [["clip", ["clip"]]]
      else
        [
          ["pbcopy", ["pbcopy"]],
          ["wl-copy", ["wl-copy"]],
          ["xclip", ["xclip", "-selection", "clipboard"]],
          ["xsel", ["xsel", "--clipboard", "--input"]]
        ]
      end
    end

    def executable?(name)
      paths = @env.fetch("PATH", "").split(File::PATH_SEPARATOR)
      extensions = windows? ? @env.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";") : [""]
      paths.any? do |path|
        extensions.any? do |extension|
          candidate = File.join(path, name + extension)
          File.file?(candidate) && File.executable?(candidate)
        end
      end
    end

    def windows?
      RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
    end

    def run_command(command, content)
      Open3.popen3(*command) do |stdin, _stdout, _stderr, wait_thread|
        stdin.write(content)
        stdin.close
        wait_thread.value.success?
      end
    rescue StandardError
      false
    end
  end
end
