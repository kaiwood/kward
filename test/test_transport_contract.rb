require_relative "test_helper"
require_relative "../lib/kward/transport"

class TestTransportContract < KwardTestCase
  def test_inbound_message_normalizes_and_freezes_nested_values
    message = Kward::Transport.inbound_message(
      conversation: Kward::Transport.conversation_key(transport_id: "test", external_id: 42),
      message_id: 7,
      actor: Kward::Transport.actor(id: 9, metadata: { "role" => ["user"] }),
      text: :hello,
      attachments: [{ name: "ignored" }],
      reply_context: { "thread" => { "id" => "abc" } },
      idempotency_key: "update:7"
    )

    assert_equal "42", message.conversation.external_id
    assert_equal "hello", message.text
    assert_equal "9", message.actor.id
    assert message.reply_context.frozen?
    assert message.reply_context["thread"].frozen?
    assert message.actor.metadata.frozen?
    assert_raises(FrozenError) { message.reply_context["thread"]["id"] = "def" }
  end

  def test_attachment_requires_exactly_one_content_source
    assert_raises(ArgumentError) do
      Kward::Transport.attachment(mime_type: "text/plain")
    end

    assert_raises(ArgumentError) do
      Kward::Transport.attachment(mime_type: "text/plain", data: "a", url: "https://example.test/a")
    end

    attachment = Kward::Transport.attachment(mime_type: "text/plain", data: "hello")
    assert_equal "hello", attachment.data
    assert_nil attachment.url
  end

  def test_capabilities_validate_streaming_mode_and_normalize_values
    capabilities = Kward::Transport.capabilities(
      inbound: ["text", :text],
      outbound: [:text],
      streaming: "edit",
      limits: { "message_bytes" => 100 }
    )

    assert_equal [:text], capabilities.inbound
    assert_equal :edit, capabilities.streaming
    assert_equal 100, capabilities.limits["message_bytes"]
    assert_raises(FrozenError) { capabilities.limits["message_bytes"] = 200 }
    assert_raises(ArgumentError) { Kward::Transport.capabilities(streaming: :unknown) }
  end

  def test_turn_event_and_interaction_request_are_structured
    event = Kward::Transport.turn_event(
      type: :assistant_message,
      session_id: "session",
      turn_id: "turn",
      sequence: "3",
      payload: { content: "Done" }
    )
    request = Kward::Transport.interaction_request(
      id: "request",
      session_id: "session",
      turn_id: "turn",
      kind: :tool_approval,
      prompt: "Allow?",
      choices: [{ id: "yes" }]
    )

    assert_equal "assistant_message", event.type
    assert_equal 3, event.sequence
    assert_equal "tool_approval", request.kind
    assert request.choices.frozen?
  end
end
