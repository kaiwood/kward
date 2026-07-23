require_relative "test_helper"
require_relative "../lib/kward/transport"

class TestTransportGateway < KwardTestCase
  def test_resolves_and_reuses_a_persisted_session_binding
    manager = FakeSessionManager.new
    Dir.mktmpdir do |root|
      gateway = Kward::Transport::Gateway.new(session_manager: manager, transport_id: "test", storage: Kward::Transport::Store.new("test", root: root))
      conversation = Kward::Transport.conversation_key(transport_id: "test", external_id: "chat:1")
      actor = Kward::Transport.actor(id: "user:1")

      first = gateway.resolve_transport_session(transport_id: "test", conversation: conversation, actor: actor, workspace_root: root)
      second = gateway.resolve_transport_session(transport_id: "test", conversation: conversation, actor: actor, workspace_root: root)

      assert_equal "rpc-1", first.id
      assert_equal "rpc-2", second.id
      assert_equal 1, manager.created.length
      assert_equal 1, manager.resumed.length
    end
  end

  def test_rejects_conversations_from_another_transport
    gateway = Kward::Transport::Gateway.new(session_manager: FakeSessionManager.new, transport_id: "test")
    conversation = Kward::Transport.conversation_key(transport_id: "other", external_id: "chat")

    assert_raises(ArgumentError) do
      gateway.resolve_transport_session(transport_id: "test", conversation: conversation, actor: Kward::Transport.actor(id: "user"))
    end
  end

  def test_normalizes_transport_attachments_for_session_manager
    manager = FakeSessionManager.new
    gateway = Kward::Transport::Gateway.new(session_manager: manager, transport_id: "test")
    attachment = Kward::Transport.attachment(mime_type: "image/png", data: "png-bytes", name: "image.png")

    gateway.start_transport_turn(session_id: "session-1", input: "look", attachments: [attachment])

    assert_equal "cG5nLWJ5dGVz", manager.started_turn[:attachments].first[:data]
    assert_equal "image/png", manager.started_turn[:attachments].first[:mimeType]
  end

  def test_forwards_runtime_interaction_requests
    manager = FakeSessionManager.new
    gateway = Kward::Transport::Gateway.new(session_manager: manager, transport_id: "test")
    requests = []
    gateway.subscribe_transport_interactions { |request| requests << request }

    manager.emit("ui/question", sessionId: "session-1", questionRequestId: "question-1", questions: [{ question: "Continue?" }])

    assert_equal "question-1", requests.first.id
    assert_equal "question", requests.first.kind
    assert_equal "Continue?", requests.first.prompt
  end

  def test_subscribes_to_normalized_turn_events_until_completion
    manager = FakeSessionManager.new
    Dir.mktmpdir do |root|
      gateway = Kward::Transport::Gateway.new(session_manager: manager, transport_id: "test", storage: Kward::Transport::Store.new("test", root: root), poll_interval: 0)
      events = []
      thread = gateway.subscribe_transport_turn(turn_id: "turn-1") { |event| events << event }
      thread.join

      assert_equal ["assistant_message", "turnFinished"], events.map(&:type)
      assert_equal [1, 2], events.map(&:sequence)
    end
  end

  class FakeSessionManager
    attr_reader :created, :resumed

    def initialize
      @created = []
      @resumed = []
      @event_reads = 0
      @event_listener = nil
      @started_turn = nil
    end

    attr_reader :started_turn

    def subscribe_events(&listener)
      @event_listener = listener
    end

    def emit(method, payload)
      @event_listener.call(method, payload)
    end

    def create_session(workspace_root:, name: nil)
      @created << [workspace_root, name]
      { id: "rpc-1", path: File.join(workspace_root, "session.jsonl"), workspaceRoot: workspace_root, name: name }
    end

    def resume_session(path:, workspace_root:, include_transcript:)
      @resumed << [path, workspace_root, include_transcript]
      { id: "rpc-2", path: path, workspaceRoot: workspace_root, name: "Resumed" }
    end

    def start_turn(**attributes)
      @started_turn = attributes
      { id: "turn-1", sessionId: attributes[:session_id] }
    end

    def turn_events(turn_id:, after_sequence:)
      @event_reads += 1
      events = [
        { sequence: 1, sessionId: "rpc-1", turnId: turn_id, type: "assistant_message", payload: { message: "Hello" } },
        { sequence: 2, sessionId: "rpc-1", turnId: turn_id, type: "turnFinished", payload: {} }
      ]
      { events: events.select { |event| event[:sequence] > after_sequence } }
    end

    def turn_status(turn_id:)
      { status: @event_reads.zero? ? "running" : "completed" }
    end
  end
end
