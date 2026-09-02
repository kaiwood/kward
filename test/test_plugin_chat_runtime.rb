require_relative "test_helper"
require_relative "../lib/kward/plugins/chat_runtime"

class TestPluginChatRuntime < KwardTestCase
  class Driver
    attr_reader :descriptor, :messages

    def initialize(descriptor)
      @descriptor = descriptor
      @messages = []
    end

    def submit(input, display_input:, cancellation:)
      @messages << { role: "user", content: input, display_input: display_input }
      cancellation.raise_if_cancelled!
      @messages << { role: "assistant", content: "Hello" }
      yield Kward::Events::AssistantDelta.new(delta: "Hello")
      yield Kward::Events::Answer.new(content: "Hello")
      "Hello"
    end
  end

  def test_scopes_non_global_plugin_chats_by_scope_key
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.bot", rpc: true, transport: true do |_host, descriptor|
        Driver.new(descriptor)
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })

    owner = runtime.open(type_id: "example.bot", surface: :transport, scope_key: "owner")
    other = runtime.open(type_id: "example.bot", surface: :transport, scope_key: "conversation:other")

    refute_same owner, other
    refute_equal owner.id, other.id
    assert_equal "owner", owner.descriptor["scope_key"]
    assert_equal "conversation:other", other.descriptor["scope_key"]
  ensure
    runtime&.shutdown
  end

  def test_exposes_shared_surface_scope_and_type_through_the_chat_host
    hosts = Queue.new
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.context", rpc: true, transport: true do |host, descriptor|
        hosts << host
        Driver.new(descriptor)
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })

    runtime.open(type_id: "example.context", surface: :transport, scope_key: "conversation:42")
    host = hosts.pop

    assert_equal "example.context", host.type_id
    assert_equal :shared, host.surface
    assert_equal "conversation:42", host.scope_key
  ensure
    runtime&.shutdown
  end

  def test_global_plugin_chats_ignore_scope_keys
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.global", singleton: :global, transport: true do |_host, descriptor|
        Driver.new(descriptor)
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })

    first = runtime.open(type_id: "example.global", surface: :transport, scope_key: "one")
    second = runtime.open(type_id: "example.global", surface: :transport, scope_key: "two")

    assert_same first, second
    assert_equal "example.global", first.id
  ensure
    runtime&.shutdown
  end

  def test_shutdown_closes_driver_and_tab_owned_resources_once
    events = Queue.new
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.cleanup", rpc: true do |host, descriptor|
        host.on_cleanup { events << :cleaned }
        host.background(name: "watcher") do |cancellation|
          events << :task_started
          sleep 0.005 until cancellation.cancelled?
          events << :task_stopped
        end
        Driver.new(descriptor).tap do |driver|
          driver.define_singleton_method(:close) { events << :driver_closed }
        end
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })

    runtime.open(type_id: "example.cleanup", surface: :rpc)
    wait_until { events.size >= 1 }
    runtime.shutdown
    runtime.shutdown

    observed = []
    observed << events.pop until events.empty?
    assert_equal 1, observed.count(:driver_closed)
    assert_equal 1, observed.count(:cleaned)
    assert_equal 1, observed.count(:task_stopped)
  ensure
    runtime&.shutdown
  end

  def test_runs_turns_and_replays_events
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "bot", id: "example.bot", transport: true do |_host, descriptor|
        Driver.new(descriptor)
      end
    end
    runtime = Kward::PluginChatRuntime.new(client: Object.new, plugin_registry_provider: -> { registry })
    chat = runtime.open(type_id: "example.bot", surface: :transport, scope_key: "owner")

    turn = runtime.start_turn(chat_id: chat.id, input: "Hi")
    wait_until { runtime.turn_status(turn_id: turn.id).status == "completed" }

    assert_equal %w[turnQueued turnStarted assistantDelta answer turnFinished], runtime.turn_events(turn_id: turn.id).map { |event| event[:type] }
    assert_equal "Hi", chat.driver.messages.first[:content]
  ensure
    runtime&.shutdown
  end
end
