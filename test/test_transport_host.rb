require_relative "test_helper"
require_relative "../lib/kward/transport"

class TestTransportHost < KwardTestCase
  def test_host_resolves_sessions_and_delegates_turn_operations
    gateway = FakeTransportGateway.new
    host = Kward::Transport::Host.new(transport_id: "test", gateway: gateway, config: { "workspace" => "/tmp/project" })
    conversation = Kward::Transport.conversation_key(transport_id: "test", external_id: "chat:1")
    actor = Kward::Transport.actor(id: "user:1")

    session = host.sessions.resolve(conversation: conversation, actor: actor)
    turn = session.start_turn("Hello", options: { approval_mode: "ask" })

    assert_equal "session-1", session.id
    assert_equal "turn-1", turn.id
    assert_equal({ "workspace" => "/tmp/project" }, host.config)
    assert_equal [:resolve, :start], gateway.calls.map(&:first)
    assert_equal "Hello", gateway.calls.find { |call| call.first == :start }[1][:input]

    assert_equal [{ type: "answer" }], turn.events
    assert_equal({ status: "running" }, turn.status)
    assert_equal :cancelled, turn.cancel
  end

  def test_host_carries_execution_profile_into_turn_gateway
    profile = Kward::Transport.execution_profile(id: "isolated_chat", tool_mode: :none, plugin_commands: false)
    gateway = FakeTransportGateway.new
    host = Kward::Transport::Host.new(transport_id: "test", gateway: gateway, execution_profile: profile)
    conversation = Kward::Transport.conversation_key(transport_id: "test", external_id: "chat:1")
    actor = Kward::Transport.actor(id: "user:1")

    host.sessions.resolve(conversation: conversation, actor: actor).start_turn("Hello")

    assert_equal profile, host.execution_profile
    assert_equal profile, gateway.calls.find { |call| call.first == :start }[1][:execution_profile]
  end

  def test_secret_reads_config_and_transport_specific_environment_fallback
    with_env(
      "KWARD_TRANSPORT_COM_EXAMPLE_TEST_TOKEN" => "environment-secret",
      "EXPLICIT_SECRET" => "explicit-secret"
    ) do
      host = Kward::Transport::Host.new(transport_id: "com.example.test", config: { "configured" => "config-secret" })

      assert_equal "config-secret", host.secret("configured")
      assert_equal "environment-secret", host.secret("token")
      assert_equal "explicit-secret", host.secret("token", env: "EXPLICIT_SECRET")
    end
  end

  def test_policy_can_reject_external_session_access
    policy = Class.new do
      def authorize(**)
        false
      end
    end.new
    host = Kward::Transport::Host.new(transport_id: "test", gateway: FakeTransportGateway.new, policy: policy)

    assert_raises(Kward::Transport::Host::PolicyDenied) do
      host.sessions.resolve(
        conversation: Kward::Transport.conversation_key(transport_id: "test", external_id: "chat"),
        actor: Kward::Transport.actor(id: "user")
      )
    end
  end

  def test_host_requires_a_gateway_for_session_access
    host = Kward::Transport::Host.new(transport_id: "test")

    assert_raises(Kward::Transport::Host::UnavailableGateway) do
      host.sessions.resolve(conversation: Kward::Transport.conversation_key(transport_id: "test", external_id: "chat"), actor: Kward::Transport.actor(id: "user"))
    end
  end

  class FakeTransportGateway
    attr_reader :calls

    def initialize
      @calls = []
    end

    def resolve_transport_session(**attributes)
      @calls << [:resolve, attributes]
      { id: "session-1", workspace_root: "/tmp/project", name: "Test" }
    end

    def start_transport_turn(**attributes)
      @calls << [:start, attributes]
      { id: "turn-1", session_id: attributes[:session_id] }
    end

    def transport_turn_events(**)
      [{ type: "answer" }]
    end

    def transport_turn_status(**)
      { status: "running" }
    end

    def cancel_transport_turn(**)
      :cancelled
    end
  end
end
