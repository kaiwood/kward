require_relative "../test_helper"
require_relative "../../lib/kward/sandbox/policy"
require_relative "../../lib/kward/sandbox/capabilities"

class TestSandboxPolicy < KwardTestCase
  def test_off_policy_preserves_no_command_write_roots
    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(workspace_root: dir)

      refute policy.enabled?
      assert_equal "deny", policy.network
      assert_equal [], policy.command_writable_roots
      assert policy.protect_git_metadata?
    end
  end

  def test_workspace_write_canonicalizes_and_deduplicates_roots
    Dir.mktmpdir do |dir|
      extra_root = File.join(dir, "extra")
      FileUtils.mkdir_p(extra_root)

      policy = Kward::Sandbox::Policy.new(
        mode: "workspace_write",
        network: "allow",
        workspace_root: File.join(dir, "."),
        writable_roots: [extra_root, File.join(extra_root, "."), dir],
        protect_git_metadata: false
      )

      assert policy.enabled?
      assert policy.workspace_write?
      assert policy.child_network_allowed?
      refute policy.protect_git_metadata?
      assert_equal [File.realpath(dir), File.realpath(extra_root)], policy.command_writable_roots
    end
  end

  def test_read_only_policy_has_no_command_write_roots
    Dir.mktmpdir do |dir|
      policy = Kward::Sandbox::Policy.new(mode: "read_only", workspace_root: dir)

      assert policy.read_only?
      assert_equal [], policy.command_writable_roots
    end
  end

  def test_policy_rejects_unknown_mode_network_and_missing_paths
    Dir.mktmpdir do |dir|
      error = assert_raises(ArgumentError) { Kward::Sandbox::Policy.new(mode: "unsafe", workspace_root: dir) }
      assert_includes error.message, "sandbox mode"

      error = assert_raises(ArgumentError) { Kward::Sandbox::Policy.new(network: "maybe", workspace_root: dir) }
      assert_includes error.message, "sandbox network"

      error = assert_raises(ArgumentError) { Kward::Sandbox::Policy.new(workspace_root: File.join(dir, "missing")) }
      assert_includes error.message, "sandbox path does not exist"
    end
  end

  def test_capabilities_return_a_frontend_neutral_payload
    capabilities = Kward::Sandbox::Capabilities.new(
      available: true,
      filesystem_enforced: true,
      child_network_enforced: false,
      backend: "macos_seatbelt",
      reason: "Network policy unavailable"
    )

    assert_equal(
      {
        available: true,
        filesystemEnforced: true,
        childNetworkEnforced: false,
        backend: "macos_seatbelt",
        reason: "Network policy unavailable"
      },
      capabilities.to_h
    )
  end
end
