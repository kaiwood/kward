require "fileutils"
require "tmpdir"
require_relative "command_runner"
require_relative "environment"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Runs a command under macOS Seatbelt. This backend deliberately constrains
    # writes and child networking first; host-process and plugin access remain
    # outside the command worker boundary.
    class MacOSSeatbeltRunner < CommandRunner
      EXECUTABLE = "/usr/bin/sandbox-exec".freeze
      PROTECTED_READ_DIRECTORIES = %w[.aws .gnupg .kward .ssh .config/gcloud .config/gh].freeze

      def self.capabilities(platform: RUBY_PLATFORM)
        available = platform.to_s.include?("darwin") && File.executable?(EXECUTABLE)
        return Capabilities.new(available: true, filesystem_enforced: true, child_network_enforced: true, backend: "macos_seatbelt") if available

        Capabilities.new(
          available: false,
          filesystem_enforced: false,
          child_network_enforced: false,
          backend: "macos_seatbelt",
          reason: "#{EXECUTABLE} is unavailable"
        )
      end

      def initialize(policy:, capabilities: self.class.capabilities)
        raise ArgumentError, "macOS Seatbelt is unavailable: #{capabilities.reason}" unless capabilities.available?

        super
      end

      def run(command, cwd:, timeout_seconds:, max_output_bytes:, cancellation: nil, &block)
        temporary_root = Dir.mktmpdir("kward-sandbox")
        environment = Environment.command_worker(temporary_root)

        LocalCommandRunner.new(
          timeout_seconds: timeout_seconds,
          max_output_bytes: max_output_bytes
        ).run(
          *command_argv(command, cwd: cwd, temporary_root: temporary_root),
          env: environment,
          cwd: cwd,
          cancellation: cancellation,
          unsetenv_others: true,
          &block
        )
      ensure
        FileUtils.remove_entry(temporary_root) if temporary_root && File.exist?(temporary_root)
      end

      def command_argv(command, cwd:, temporary_root: nil)
        temporary_root ||= Dir.tmpdir
        [EXECUTABLE, "-p", profile(temporary_root), "/bin/zsh", "-lc", command.to_s]
      end

      private

      def profile(temporary_root)
        writable_roots = policy.command_writable_roots + [File.realpath(temporary_root)]
        rules = [
          "(version 1)",
          "(deny default)",
          "(allow process*)",
          "(allow signal)",
          "(allow file-read*)",
          "(allow file-write-data (literal \"/dev/null\"))",
          "(allow sysctl-read)",
          "(allow mach-lookup)",
          "(allow ipc-posix-shm*)",
          "(allow user-preference-read)",
          "(allow pseudo-tty)"
        ]
        rules << "(allow network*)" if policy.child_network_allowed?
        rules.concat(writable_roots.map { |path| "(allow file-write* (subpath #{seatbelt_string(path)}))" })
        rules.concat(protected_read_roots.map { |path| "(deny file-read* (subpath #{seatbelt_string(path)}))" })
        rules << "(deny file-write* (subpath #{seatbelt_string(File.join(policy.workspace_root, ".git"))}))" if policy.protect_git_metadata?
        rules.join("\n")
      end

      def protected_read_roots
        home = ENV.fetch("HOME", Dir.home)
        PROTECTED_READ_DIRECTORIES.map do |path|
          root = File.join(home, path)
          File.exist?(root) ? File.realpath(root) : root
        end
      end

      def seatbelt_string(value)
        %Q{"#{value.to_s.gsub(/([\\"])/, '\\\\1')}"}
      end
    end
  end
end
