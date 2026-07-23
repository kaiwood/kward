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
    end

    def create_session(workspace_root:, name: nil)
      @created << [workspace_root, name]
      { id: "rpc-1", path: File.join(workspace_root, "session.jsonl"), workspaceRoot: workspace_root, name: name }
    end

    def resume_session(path:, workspace_root:, include_transcript:)
      @resumed << [path, workspace_root, include_transcript]
      { id: "rpc-2", path: path, workspaceRoot: workspace_root, name: "Resumed" }
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
