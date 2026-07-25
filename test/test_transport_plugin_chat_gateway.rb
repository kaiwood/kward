require_relative "test_helper"
require_relative "../lib/kward/transport/plugin_chat_gateway"

class TestTransportPluginChatGateway < KwardTestCase
  class Driver
    attr_reader :messages

    def initialize(_descriptor)
      @messages = []
    end

    def submit(input, display_input:, cancellation:)
      @messages << { role: "user", content: input, display_input: display_input }
      cancellation.raise_if_cancelled!
      @messages << { role: "assistant", content: "Done" }
      yield Kward::Events::AssistantDelta.new(delta: "Done")
      yield Kward::Events::Answer.new(content: "Done")
      "Done"
    end
  end

  def test_resolves_scoped_chat_and_streams_transport_events
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.bot", transport: true do |_host, descriptor|
        Driver.new(descriptor)
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })
    gateway = Kward::Transport::PluginChatGateway.new(runtime: runtime, transport_id: "example.transport", poll_interval: 0)
    host = Kward::Transport::Host.new(transport_id: "example.transport", plugin_chat_gateway: gateway)
    conversation = Kward::Transport.conversation_key(transport_id: "example.transport", external_id: "telegram:chat:1")
    actor = Kward::Transport.actor(id: "telegram:user:1", display_name: "Owner")

    chat = host.plugin_chats.resolve(
      type_id: "example.bot",
      conversation: conversation,
      actor: actor,
      scope_key: "conversation:telegram:chat:1"
    )
    turn = chat.start_turn(
      "hello",
      attachments: [Kward::Transport.attachment(mime_type: "image/png", data: "image-bytes", name: "photo.png")]
    )
    wait_until { turn.status[:status] == "completed" }

    assert_equal "example.bot", chat.type_id
    assert_equal "conversation:telegram:chat:1", chat.scope_key
    assert_equal %w[turnQueued turnStarted assistantDelta answer turnFinished], turn.events.map(&:type)
    assert_equal "Done", chat.transcript[:messages].last[:content]
    input = runtime.chat(chat.id).driver.messages.first[:content]
    assert_equal "aW1hZ2UtYnl0ZXM=", input.last[:data]
    assert_equal "image/png", input.last[:media_type]
  ensure
    host&.shutdown
    runtime&.shutdown
  end

  def test_transport_policy_can_reject_plugin_chat_resolution
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.bot", transport: true do |_host, descriptor|
        Driver.new(descriptor)
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })
    gateway = Kward::Transport::PluginChatGateway.new(runtime: runtime, transport_id: "example.transport")
    policy = Class.new do
      def authorize(action:, **)
        action != :resolve_plugin_chat
      end
    end.new
    host = Kward::Transport::Host.new(transport_id: "example.transport", plugin_chat_gateway: gateway, policy: policy)

    assert_raises(Kward::Transport::Host::PolicyDenied) do
      host.plugin_chats.resolve(
        type_id: "example.bot",
        conversation: Kward::Transport.conversation_key(transport_id: "example.transport", external_id: "chat"),
        actor: Kward::Transport.actor(id: "user")
      )
    end
  ensure
    host&.shutdown
    runtime&.shutdown
  end
end
