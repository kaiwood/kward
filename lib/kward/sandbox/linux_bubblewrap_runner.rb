require "fileutils"
require "tmpdir"
require_relative "command_runner"

# Namespace for operating-system command sandboxing.
module Kward
  module Sandbox
    # Runs a command in a Bubblewrap mount namespace on Linux.
    class LinuxBubblewrapRunner < CommandRunner
      def self.executable
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
          path = File.expand_path("bwrap", directory)
          path if File.file?(path) && File.executable?(path)
        end.first
      end

      def self.capabilities(platform: RUBY_PLATFORM, executable: self.executable)
        available = platform.to_s.include?("linux") && !executable.to_s.empty?
        return Capabilities.new(available: true, filesystem_enforced: true, child_network_enforced: true, backend: "linux_bubblewrap") if available

        Capabilities.new(
          available: false,
          filesystem_enforced: false,
          child_network_enforced: false,
          backend: "linux_bubblewrap",
          reason: "Bubblewrap is unavailable"
        )
      end

      def initialize(policy:, executable: self.class.executable, capabilities: self.class.capabilities(executable: executable))
        raise ArgumentError, "Linux Bubblewrap is unavailable: #{capabilities.reason}" unless capabilities.available?

        super(policy:, capabilities:)
        @executable = executable
      end

      def run(command, cwd:, timeout_seconds:, max_output_bytes:, cancellation: nil, &block)
        temporary_root = Dir.mktmpdir("kward-sandbox")
        environment = {
          "TMPDIR" => temporary_root,
          "TMP" => temporary_root,
          "TEMP" => temporary_root
        }

        LocalCommandRunner.new(
          timeout_seconds: timeout_seconds,
          max_output_bytes: max_output_bytes
        ).run(
          *command_argv(command, cwd: cwd, temporary_root: temporary_root),
          env: environment,
          cwd: cwd,
          cancellation: cancellation,
          &block
        )
      ensure
        FileUtils.remove_entry(temporary_root) if temporary_root && File.exist?(temporary_root)
      end

      def command_argv(command, cwd:, temporary_root: nil)
        temporary_root ||= Dir.tmpdir
        workspace_root = policy.workspace_root
        writable_roots = policy.command_writable_roots + [File.realpath(temporary_root)]
        argv = [@executable, "--die-with-parent", "--new-session", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"]
        argv << "--unshare-net" unless policy.child_network_allowed?
        argv.concat(["--bind", workspace_root, workspace_root]) if policy.workspace_write?
        writable_roots.reject { |path| path == workspace_root }.each { |path| argv.concat(["--bind", path, path]) }
        argv.concat(["--ro-bind", File.join(workspace_root, ".git"), File.join(workspace_root, ".git")]) if policy.protect_git_metadata? && File.exist?(File.join(workspace_root, ".git"))
        argv.concat(["--setenv", "TMPDIR", temporary_root, "--setenv", "TMP", temporary_root, "--setenv", "TEMP", temporary_root])
        argv.concat(["--chdir", cwd.to_s, "--", "/bin/sh", "-lc", command.to_s])
      end
    end
  end
end
