require_relative "test_helper"
require_relative "../lib/kward/transport"

class TestTransportManager < KwardTestCase
  def test_starts_stops_and_reports_registered_transport
    registry = Kward::PluginRegistry.new
    lifecycle = []
    registry.evaluate do |plugin|
      plugin.transport("fake", id: "com.example.fake", capabilities: { outbound: [:text] }) do |_host, config|
        lifecycle << [:build, config]
        Class.new do
          define_method(:start) { lifecycle << :start }
          define_method(:stop) { lifecycle << :stop }
          define_method(:health) { :healthy }
        end.new
      end
    end

    Dir.mktmpdir do |root|
      manager = Kward::Transport::Manager.new(registry: registry, config_root: root)
      assert_equal "stopped", manager.status("fake")[:state]

      manager.start("fake", config: { "token" => "secret" })
      assert_equal "running", manager.status("com.example.fake")[:state]
      assert_equal :healthy, manager.status("fake")[:health]
      assert_equal [:build, { "token" => "secret" }], lifecycle[0]
      assert_equal :start, lifecycle[1]

      assert_raises(RuntimeError) { manager.start("fake") }
      assert manager.stop("fake")
      assert_equal "stopped", manager.status("fake")[:state]
      assert_equal :stop, lifecycle.last
    end
  end

  def test_reload_replaces_registered_transport_types
    first = Kward::PluginRegistry.new
    first.evaluate { |plugin| plugin.transport("one", id: "com.example.one") { Class.new { def start; end; def stop; end }.new } }
    second = Kward::PluginRegistry.new
    second.evaluate { |plugin| plugin.transport("two", id: "com.example.two") { Class.new { def start; end; def stop; end }.new } }

    manager = Kward::Transport::Manager.new(registry: first)
    assert_equal ["com.example.two"], manager.reload(second).map { |entry| entry[:id] }
  end

  def test_failed_start_is_recorded_and_re_raised
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.transport("broken", id: "com.example.broken") do
        Class.new do
          def start
            raise "network unavailable"
          end

          def stop; end
        end.new
      end
    end

    error_output = StringIO.new
    logger = Logger.new(error_output)
    manager = Kward::Transport::Manager.new(registry: registry, logger: logger)

    assert_raises(RuntimeError, "network unavailable") { manager.start("broken") }
    status = manager.status("broken")
    assert_equal "failed", status[:state]
    assert_equal "network unavailable", status[:error]
    assert_includes error_output.string, "com.example.broken"
  end

  def test_shutdown_stops_running_transports
    registry = Kward::PluginRegistry.new
    stopped = false
    registry.evaluate do |plugin|
      plugin.transport("fake", id: "com.example.fake") do
        Class.new do
          define_method(:start) {}
          define_method(:stop) { stopped = true }
        end.new
      end
    end

    manager = Kward::Transport::Manager.new(registry: registry)
    manager.start("fake")
    manager.shutdown

    assert stopped
    assert_equal "stopped", manager.status("fake")[:state]
  end
end
