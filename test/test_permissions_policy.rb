require_relative "test_helper"
require_relative "../lib/kward/permissions/policy"

class TestPermissionsPolicy < KwardTestCase
  def test_is_disabled_by_default
    policy = Kward::Permissions::Policy.new

    decision = policy.decision_for("run_shell_command", { command: "echo hello" })

    assert decision.allowed?
    assert_equal "permissions disabled", decision.reason
  end

  def test_ask_mode_allows_reads_and_asks_for_risky_tools
    policy = Kward::Permissions::Policy.new(enabled: true)

    assert policy.decision_for("read_file", { path: "README.md" }).allowed?
    assert policy.decision_for("write_file", { path: "lib/kward.rb" }).approval_required?
    assert policy.decision_for("run_shell_command", { command: "bundle exec rake" }).approval_required?
    assert policy.decision_for("fetch_content", { url: "https://example.com" }).approval_required?
  end

  def test_deny_rules_take_precedence_over_ask_and_allow_rules
    policy = Kward::Permissions::Policy.new(
      enabled: true,
      allow: [{ tool: "run_shell_command" }],
      ask: [{ tool: "run_shell_command" }],
      deny: [{ tool: "run_shell_command", command: "git push*" }]
    )

    assert policy.decision_for("run_shell_command", { command: "bundle exec rake" }).approval_required?
    assert policy.decision_for("run_shell_command", { command: "git push origin main" }).denied?
  end

  def test_workspace_write_mode_allows_writes_in_configured_scopes
    policy = Kward::Permissions::Policy.new(enabled: true, mode: "workspace-write", write_scopes: ["lib/**", "test/**"])

    assert policy.decision_for("edit_file", { path: "lib/kward/workspace.rb" }).allowed?
    assert policy.decision_for("write_file", { path: "test/test_workspace.rb" }).allowed?
    assert policy.decision_for("write_file", { path: "README.md" }).denied?
  end

  def test_read_only_and_deny_by_default_modes_deny_risky_tools
    %w[read-only deny-by-default].each do |mode|
      policy = Kward::Permissions::Policy.new(enabled: true, mode: mode)

      assert policy.decision_for("read_file", { path: "README.md" }).allowed?
      assert policy.decision_for("write_file", { path: "README.md" }).denied?
      assert policy.decision_for("run_shell_command", { command: "echo hello" }).denied?
    end
  end

  def test_treats_mcp_tools_as_risky
    policy = Kward::Permissions::Policy.new(enabled: true)

    assert policy.decision_for("browser_console", {}, source: "mcp").approval_required?
  end

  def test_fetch_rules_match_requested_host
    policy = Kward::Permissions::Policy.new(enabled: true, allow: [{ tool: "fetch_content", host: "*.example.com" }])

    assert policy.decision_for("fetch_content", { url: "https://api.example.com/v1" }).allowed?
    assert policy.decision_for("fetch_content", { url: "https://example.org" }).approval_required?
  end
end
