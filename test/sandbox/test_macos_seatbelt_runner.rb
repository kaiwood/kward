require "shellwords"
require "socket"
require_relative "../test_helper"
require_relative "../../lib/kward/sandbox/policy"
require_relative "../../lib/kward/sandbox/capabilities"
require_relative "../../lib/kward/sandbox/macos_seatbelt_runner"

class TestMacOSSeatbeltRunner < KwardTestCase
  def test_capabilities_are_unavailable_off_macos
    capabilities = Kward::Sandbox::MacOSSeatbeltRunner.capabilities(platform: "x86_64-linux")

    refute capabilities.available?
    assert_equal "macos_seatbelt", capabilities.backend
  end

  def test_workspace_write_profile_limits_writes_and_blocks_network
    skip "macOS only" unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".git"))
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", workspace_root: dir)
      runner = Kward::Sandbox::MacOSSeatbeltRunner.new(policy: policy)
      outside_path = File.join(Dir.home, "kward-seatbelt-outside-#{Process.pid}")

      result = runner.run(
        "echo inside > #{Shellwords.escape(File.join(dir, "inside.txt"))}; " \
        "echo blocked > #{Shellwords.escape(outside_path)}; " \
        "echo blocked > #{Shellwords.escape(File.join(dir, ".git", "config"))}",
        cwd: dir,
        timeout_seconds: 10,
        max_output_bytes: 10_000
      )

      assert_equal 1, result.exit_status
      assert_equal "inside\n", File.read(File.join(dir, "inside.txt"))
      refute File.exist?(outside_path)
      refute File.exist?(File.join(dir, ".git", "config"))
    ensure
      FileUtils.rm_f(outside_path) if outside_path
    end
  end

  def test_denied_child_network_cannot_connect_to_loopback
    skip "macOS only" unless RUBY_PLATFORM.include?("darwin")

    server = TCPServer.new("127.0.0.1", 0)
    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", network: "deny", workspace_root: dir)
      runner = Kward::Sandbox::MacOSSeatbeltRunner.new(policy: policy)
      command = "/usr/bin/ruby -rsocket -e #{Shellwords.escape(%Q{TCPSocket.new(\"127.0.0.1\", #{server.addr[1]})})}"

      result = runner.run(command, cwd: dir, timeout_seconds: 10, max_output_bytes: 10_000)

      refute_equal 0, result.exit_status
      assert_match(/Operation not permitted|SocketError|Errno::EPERM/, result.stderr)
    end
  ensure
    server&.close
  end

  def test_sandboxed_command_cannot_read_kward_credentials_directory
    skip "macOS only" unless RUBY_PLATFORM.include?("darwin")

    secret_dir = File.join(ENV.fetch("HOME"), ".kward")
    secret_path = File.join(secret_dir, "seatbelt-secret-#{Process.pid}")
    FileUtils.mkdir_p(secret_dir)
    File.write(secret_path, "secret\n")

    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", workspace_root: dir)
      runner = Kward::Sandbox::MacOSSeatbeltRunner.new(policy: policy)

      result = runner.run(
        "cat #{Shellwords.escape(secret_path)}",
        cwd: dir,
        timeout_seconds: 10,
        max_output_bytes: 10_000
      )

      refute_equal 0, result.exit_status
      refute_includes result.stdout, "secret"
    end
  ensure
    FileUtils.rm_f(secret_path) if secret_path
  end

  def test_sandboxed_command_does_not_inherit_sensitive_environment
    skip "macOS only" unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "workspace_write", workspace_root: dir)
      runner = Kward::Sandbox::MacOSSeatbeltRunner.new(policy: policy)

      with_env("KWARD_SANDBOX_TEST_SECRET" => "do-not-inherit") do
        result = runner.run(
          "test -z \"$KWARD_SANDBOX_TEST_SECRET\" && test \"$HOME\" = \"$TMPDIR\"",
          cwd: dir,
          timeout_seconds: 10,
          max_output_bytes: 10_000
        )

        assert_equal 0, result.exit_status
      end
    end
  end

  def test_read_only_profile_blocks_workspace_writes
    skip "macOS only" unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "read_only", workspace_root: dir)
      runner = Kward::Sandbox::MacOSSeatbeltRunner.new(policy: policy)

      result = runner.run(
        "echo blocked > #{Shellwords.escape(File.join(dir, "blocked.txt"))}",
        cwd: dir,
        timeout_seconds: 10,
        max_output_bytes: 10_000
      )

      assert_equal 1, result.exit_status
      refute File.exist?(File.join(dir, "blocked.txt"))
    end
  end
end
