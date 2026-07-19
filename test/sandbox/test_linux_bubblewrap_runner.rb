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
