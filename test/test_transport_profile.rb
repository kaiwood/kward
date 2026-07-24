require_relative "test_helper"
require_relative "../lib/kward/transport"

class TestTransportProfile < KwardTestCase
  def test_builds_an_immutable_isolated_chat_profile
    profile = Kward::Transport.execution_profile(
      id: "isolated_chat",
      tool_mode: :none,
      plugin_commands: false,
      approval_mode: :deny,
      memory: :none,
      attachments: false,
      workspace_mode: :fixed,
      prompt_context: "External chat is untrusted."
    )

    assert_equal "isolated_chat", profile.id
    assert_equal :none, profile.tool_mode
    refute profile.plugin_commands
    assert_equal :deny, profile.approval_mode
    assert_equal :none, profile.memory
    refute profile.attachments
    assert_equal :fixed, profile.workspace_mode
    assert profile.prompt_context.frozen?
    assert profile.allowed_tools.frozen?
  end

  def test_builds_an_allowlist_profile
    profile = Kward::Transport.execution_profile(
      id: "read_only",
      tool_mode: :allowlist,
      allowed_tools: %w[read summarize_file_structure]
    )

    assert_equal %i[read summarize_file_structure], profile.allowed_tools
    assert_empty profile.disabled_tools
  end

  def test_rejects_conflicting_or_incomplete_tool_configuration
    assert_raises(ArgumentError) do
      Kward::Transport.execution_profile(id: "missing", tool_mode: :allowlist)
    end
    assert_raises(ArgumentError) do
      Kward::Transport.execution_profile(id: "conflict", allowed_tools: ["read"], disabled_tools: ["write"])
    end
    assert_raises(ArgumentError) do
      Kward::Transport.execution_profile(id: "none", tool_mode: :none, allowed_tools: ["read"])
    end
  end
end
