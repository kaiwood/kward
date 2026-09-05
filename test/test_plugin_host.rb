require_relative "test_helper"

class TestPluginHost < KwardTestCase
  def test_reads_frozen_namespaced_config_and_secrets
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump(
        "plugins" => {
          "com.example.demo" => {
            "endpoint" => "https://example.test",
            "token" => "config-secret"
          }
        }
      ))

      with_env(
        "KWARD_CONFIG_PATH" => config_path,
        "KWARD_PLUGIN_COM_EXAMPLE_DEMO_FALLBACK" => "default-env-secret",
        "DEMO_TOKEN" => "explicit-env-secret"
      ) do
        host = Kward::PluginHost.new(
          id: "com.example.demo",
          version: "1.2.0",
          api_version: "1",
          source_path: "/plugins/demo.rb"
        )

        assert_equal "com.example.demo", host.id
        assert_equal "1.2.0", host.version
        assert_equal "1", host.api_version
        assert_equal "/plugins/demo.rb", host.source_path
        assert_equal "https://example.test", host.config["endpoint"]
        assert host.config.frozen?
        assert_equal "config-secret", host.secret("token", env: "DEMO_TOKEN")
        assert_equal "explicit-env-secret", host.secret("missing", env: "DEMO_TOKEN")
        assert_equal "default-env-secret", host.secret("fallback")
        assert_equal({ id: "com.example.demo", version: "1.2.0", api_version: "1" }, host.to_h)
      end
    end
  end

  def test_logger_uses_kward_diagnostic_sink
    previous_sink = Kward::ConfigFiles.warning_sink
    messages = []
    Kward::ConfigFiles.warning_sink = messages.method(:<<)
    host = Kward::PluginHost.new(id: "com.example.demo", version: "1", api_version: "1", config: {})

    host.logger.info("ready")

    assert_equal 1, messages.length
    assert_includes messages.first, "Kward plugin com.example.demo"
    assert_includes messages.first, "ready"
  ensure
    Kward::ConfigFiles.warning_sink = previous_sink
  end

  def test_storage_is_durable_private_and_returns_copies
    Dir.mktmpdir do |root|
      store = Kward::PluginStore.new("com.example.demo", root: root)
      value = { "items" => ["one"] }

      store.put("cache", value)
      value["items"] << "caller-change"
      loaded = store.get("cache")
      loaded["items"] << "loaded-change"

      assert_equal({ "items" => ["one"] }, store.get("cache"))
      assert_equal({ "items" => ["one"] }, Kward::PluginStore.new("com.example.demo", root: root).get("cache"))

      path = File.join(root, "plugin_state", "com.example.demo", "state.json")
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal({ "items" => ["one"] }, store.delete("cache"))
      assert_nil store.get("cache")
    end
  end

  def test_rejects_invalid_plugin_and_storage_ids
    assert_raises(ArgumentError) do
      Kward::PluginHost.new(id: "../demo", version: "1", api_version: "1", config: {})
    end
    assert_raises(ArgumentError) { Kward::PluginStore.new("../demo") }
  end
end
