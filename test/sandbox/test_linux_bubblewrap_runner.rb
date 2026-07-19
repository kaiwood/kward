require "shellwords"
require "socket"
require_relative "../test_helper"
require_relative "../../lib/kward/sandbox/policy"
require_relative "../../lib/kward/sandbox/capabilities"
require_relative "../../lib/kward/sandbox/linux_bubblewrap_runner"

class TestLinuxBubblewrapRunner < KwardTestCase
  def test_capabilities_are_unavailable_without_bubblewrap
    capabilities = Kward::Sandbox::LinuxBubblewrapRunner.capabilities(platform: "x86_64-linux", executable: nil)

    refute capabilities.available?
    assert_equal "linux_bubblewrap", capabilities.backend
    assert_equal "Bubblewrap is unavailable", capabilities.reason
  end

  def test_workspace_write_binds_only_workspace_and_temp_for_writes
    Dir.mktmpdir do |dir|
      git_dir = File.join(dir, ".git")
      temp_dir = File.join(dir, "temp")
      FileUtils.mkdir_p([git_dir, temp_dir])
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", workspace_root: dir)
      capabilities = Kward::Sandbox::Capabilities.new(available: true, filesystem_enforced: true, child_network_enforced: true, backend: "linux_bubblewrap")
      runner = Kward::Sandbox::LinuxBubblewrapRunner.new(policy: policy, executable: "/usr/bin/bwrap", capabilities: capabilities)

      argv = runner.command_argv("echo hello", cwd: dir, temporary_root: temp_dir)

      assert_includes argv, "--unshare-net"
      assert_includes argv.each_cons(3).to_a, ["--bind", File.realpath(dir), File.realpath(dir)]
      assert_includes argv.each_cons(3).to_a, ["--bind", File.realpath(temp_dir), File.realpath(temp_dir)]
      assert_includes argv.each_cons(3).to_a, ["--ro-bind", File.realpath(git_dir), File.realpath(git_dir)]
      assert_equal ["--", "/bin/sh", "-lc", "echo hello"], argv.last(4)
    end
  end

  def test_workspace_write_enforces_filesystem_boundary
    skip "Bubblewrap integration tests are disabled" unless ENV["KWARD_RUN_BUBBLEWRAP_TESTS"] == "1"
    skip "Linux only" unless RUBY_PLATFORM.include?("linux")

    Dir.mktmpdir do |parent|
      workspace = File.join(parent, "workspace")
      outside_path = File.join(parent, "outside.txt")
      FileUtils.mkdir_p(workspace)
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", workspace_root: workspace)
      runner = Kward::Sandbox::LinuxBubblewrapRunner.new(policy: policy)

      result = runner.run(
        "echo inside > #{Shellwords.escape(File.join(workspace, "inside.txt"))}; " \
        "echo blocked > #{Shellwords.escape(outside_path)}",
        cwd: workspace,
        timeout_seconds: 10,
        max_output_bytes: 10_000
      )

      assert_equal 1, result.exit_status
      assert_equal "inside\n", File.read(File.join(workspace, "inside.txt"))
      refute File.exist?(outside_path)
    end
  end

  def test_denied_child_network_cannot_connect_to_loopback
    skip "Bubblewrap integration tests are disabled" unless ENV["KWARD_RUN_BUBBLEWRAP_TESTS"] == "1"
    skip "Linux only" unless RUBY_PLATFORM.include?("linux")

    server = TCPServer.new("127.0.0.1", 0)
    Dir.mktmpdir do |workspace|
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", network: "deny", workspace_root: workspace)
      runner = Kward::Sandbox::LinuxBubblewrapRunner.new(policy: policy)
      ruby = Shellwords.escape(RbConfig.ruby)
      source = Shellwords.escape(%Q{TCPSocket.new(\"127.0.0.1\", #{server.addr[1]})})

      result = runner.run(
        "#{ruby} -rsocket -e #{source}",
        cwd: workspace,
        timeout_seconds: 10,
        max_output_bytes: 10_000
      )

      refute_equal 0, result.exit_status
    end
  ensure
    server&.close
  end

  def test_read_only_does_not_bind_workspace_writable
    Dir.mktmpdir do |dir|
      temp_dir = File.join(dir, "temp")
      FileUtils.mkdir_p(temp_dir)
      policy = Kward::Sandbox::Policy.new(mode: "read_only", workspace_root: dir)
      capabilities = Kward::Sandbox::Capabilities.new(available: true, filesystem_enforced: true, child_network_enforced: true, backend: "linux_bubblewrap")
      runner = Kward::Sandbox::LinuxBubblewrapRunner.new(policy: policy, executable: "/usr/bin/bwrap", capabilities: capabilities)

      argv = runner.command_argv("echo hello", cwd: dir, temporary_root: temp_dir)

      refute_includes argv.each_cons(3).to_a, ["--bind", File.realpath(dir), File.realpath(dir)]
      assert_includes argv.each_cons(3).to_a, ["--bind", File.realpath(temp_dir), File.realpath(temp_dir)]
    end
  end
end
