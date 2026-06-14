require "open3"
require "rbconfig"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Best-effort session file remover. Uses the OS trash/recycle bin when a
  # supported platform tool is available, and falls back to permanent deletion.
  class SessionTrash
    def initialize(env: ENV, command_runner: nil, host_os: RbConfig::CONFIG["host_os"])
      @env = env
      @command_runner = command_runner || method(:run_command)
      @host_os = host_os
    end

    def delete(path)
      return false unless File.exist?(path)

      return true if move_to_trash(path)

      File.delete(path) if File.exist?(path)
      true
    end

    private

    def move_to_trash(path)
      trash_commands.each do |name, command|
        next unless executable?(name)

        return true if @command_runner.call(command, path) && !File.exist?(path)
      end

      false
    end

    def trash_commands
      if windows?
        powershell_trash_commands
      elsif macos?
        [["osascript", ["osascript", "-e", "on run argv", "-e", "tell application \"Finder\" to delete POSIX file (item 1 of argv)", "-e", "end run"]]]
      else
        [
          ["gio", ["gio", "trash"]],
          ["trash-put", ["trash-put"]],
          ["kioclient5", ["kioclient5", "move", nil, "trash:/"]],
          ["kioclient", ["kioclient", "move", nil, "trash:/"]]
        ]
      end
    end

    def powershell_trash_commands
      script = <<~POWERSHELL.strip
        Add-Type -AssemblyName Microsoft.VisualBasic;
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($args[0], 'OnlyErrorDialogs', 'SendToRecycleBin')
      POWERSHELL
      [
        ["pwsh", ["pwsh", "-NoProfile", "-Command", script]],
        ["powershell", ["powershell", "-NoProfile", "-Command", script]]
      ]
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

    def run_command(command, path)
      command = if command.include?(nil)
                  command.map { |part| part || path }
                else
                  command + [path]
                end
      _stdout, _stderr, status = Open3.capture3(*command)
      status.success?
    rescue StandardError
      false
    end

    def macos?
      host_os.match?(/darwin/i)
    end

    def windows?
      host_os.match?(/mswin|mingw|cygwin/i)
    end

    def host_os
      @host_os
    end
  end
end
