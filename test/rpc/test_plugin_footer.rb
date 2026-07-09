require_relative "test_support"

class TestRPCPluginFooter < KwardTestCase
  include KwardRPCTestSupport

  def test_rpc_plugin_footer_notifications_include_session_text
    Dir.mktmpdir do |config_dir|
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.footer do |ctx|
          "#{ctx.session_name || "unnamed"} #{ctx.transcript.messages.length} messages"
        end
      end
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: RecordingClient.new(["done"]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)

      session = manager.create_session(workspace_root: Dir.pwd, name: "Bridge")
      create_footer = manager.instance_variable_get(:@server).notifications.find { |notification| notification[:method] == "ui/footer" }
      assert_equal({ sessionId: session[:id], text: "Bridge 0 messages" }, create_footer[:params])

      turn = manager.start_turn(session_id: session[:id], input: "hello")
      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      footer_notifications = manager.instance_variable_get(:@server).notifications.select { |notification| notification[:method] == "ui/footer" }
      assert_equal({ sessionId: session[:id], text: "Bridge 2 messages" }, footer_notifications.last[:params])
    end
  end

  def test_rpc_reload_starts_and_clears_plugin_footer
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |home|
        plugins_dir = File.join(home, ".kward", "plugins")
        plugin_path = File.join(plugins_dir, "footer.rb")
        FileUtils.mkdir_p(plugins_dir)
        server = RecordingServer.new
        manager = Kward::RPC::SessionManager.new(server: server, client: FakeClient.new([]), config_dir: config_dir)
        session = nil

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
          session = manager.create_session(workspace_root: Dir.pwd)
          File.write(plugin_path, <<~'RUBY')
            Kward.plugin do |plugin|
              plugin.footer do |_ctx|
                "Reloaded footer"
              end
            end
          RUBY

          manager.reload_plugins
          File.delete(plugin_path)
          manager.reload_plugins
        end

        footer_notifications = server.notifications.select { |notification| notification[:method] == "ui/footer" }
        assert_equal({ sessionId: session[:id], text: "Reloaded footer" }, footer_notifications.first[:params])
        assert_equal({ sessionId: session[:id], text: "" }, footer_notifications.last[:params])
        manager.close_session(session_id: session[:id])
      end
    end
  end

  def test_rpc_reload_rebuilds_existing_session_hook_runtime
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |home|
        plugins_dir = File.join(home, ".kward", "plugins")
        plugin_path = File.join(plugins_dir, "hook.rb")
        FileUtils.mkdir_p(plugins_dir)
        client = RecordingClient.new(["done"])
        manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
        session = nil

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
          session = manager.create_session(workspace_root: Dir.pwd)
          File.write(plugin_path, <<~'RUBY')
            Kward.plugin do |plugin|
              plugin.hook "model_request_before" do |_event, ctx|
                ctx.modify({ model: "plugin-model" })
              end
            end
          RUBY

          manager.reload_plugins
          turn = manager.start_turn(session_id: session[:id], input: "hello")
          wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
        end

        assert_equal "plugin-model", client.requests.last[:model]
        manager.close_session(session_id: session[:id])
      end
    end
  end

  def test_rpc_plugin_footer_refreshes_on_interval
    original_interval = Kward::RPC::SessionManager::FOOTER_REFRESH_INTERVAL
    Kward::RPC::SessionManager.send(:remove_const, :FOOTER_REFRESH_INTERVAL)
    Kward::RPC::SessionManager.const_set(:FOOTER_REFRESH_INTERVAL, 0.01)

    Dir.mktmpdir do |config_dir|
      count = 0
      registry = Kward::PluginRegistry.new
      registry.evaluate do |plugin|
        plugin.footer do |_ctx|
          count += 1
          "tick #{count}"
        end
      end
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: FakeClient.new([]), config_dir: config_dir)
      manager.instance_variable_set(:@plugin_registry, registry)

      session = manager.create_session(workspace_root: Dir.pwd)
      wait_until { server.notifications.count { |notification| notification[:method] == "ui/footer" } >= 2 }

      footer_notifications = server.notifications.select { |notification| notification[:method] == "ui/footer" }
      assert_equal({ sessionId: session[:id], text: "tick 1" }, footer_notifications.first[:params])
      assert_equal({ sessionId: session[:id], text: "tick 2" }, footer_notifications[1][:params])
      manager.close_session(session_id: session[:id])
    end
  ensure
    Kward::RPC::SessionManager.send(:remove_const, :FOOTER_REFRESH_INTERVAL)
    Kward::RPC::SessionManager.const_set(:FOOTER_REFRESH_INTERVAL, original_interval)
  end

end
