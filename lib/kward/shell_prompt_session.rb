require_relative "ansi"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Scoped bridge between a transient shell-agent turn and the live shell state.
  class ShellPromptSession
    MAX_PREPARED_COMMAND_BYTES = 32_000
    UNSAFE_COMMAND_CONTROL_PATTERN = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\r]/.freeze

    attr_reader :shell

    def initialize(shell)
      @shell = shell
      @prepared_command = nil
    end

    def context
      @shell.context_snapshot
    end

    def timeout_seconds
      @shell.timeout_seconds
    end

    def run(command, timeout_seconds: nil, cancellation: nil)
      raise ArgumentError, "A shell command is required." if command.to_s.strip.empty?

      result = @shell.run_for_agent(command, timeout_seconds: timeout_seconds, cancellation: cancellation)
      format_result(result)
    end

    def prepare(command)
      value = command.to_s
      raise ArgumentError, "A shell command is required." if value.strip.empty?
      raise ArgumentError, "Prepared shell command is too large." if value.bytesize > MAX_PREPARED_COMMAND_BYTES
      raise ArgumentError, "Prepared shell command contains unsafe control characters." if value.match?(UNSAFE_COMMAND_CONTROL_PATTERN)

      @prepared_command = value
      "Prepared the command in the shell prompt. It will not run until you press Enter."
    end

    def prepared_command
      @prepared_command&.dup
    end

    private

    def format_result(result)
      lines = [
        "Exit status: #{result.exit_status}",
        "Current directory: #{shell.cwd}"
      ]
      output = ANSI.normalize_transcript_encoding(result.output.to_s)
      lines << "\nSTDOUT:\n#{output}" unless output.empty?
      lines.join("\n")
    end
  end
end
