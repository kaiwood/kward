require_relative "test_helper"

class TestPluginRegistry < KwardTestCase
  def test_loads_ruby_plugin_commands_and_footer
    Dir.mktmpdir do |home|
      plugins = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins)
      plugin_path = File.join(plugins, "demo.rb")
      File.write(plugin_path, <<~'RUBY')
        Kward.plugin do |plugin|
          plugin.command "hello", description: "Say hello", argument_hint: "<name>" do |args, ctx|
            ctx.say("Hello #{args}")
            "done"
          end

          plugin.footer do |ctx|
            "#{ctx.transcript.messages.length} messages"
          end
        end
      RUBY

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        registry = Kward::PluginRegistry.load
        command = registry.command_for("hello")
        conversation = Kward::Conversation.new(system_message: nil)
        conversation.append_user("hi")
        output = []
        context = Kward::PluginRegistry::Context.new(conversation: conversation, args: "Klingon", say_callback: lambda { |message| output << message })

        assert_equal "Say hello", command.description
        assert_equal "<name>", command.argument_hint
        assert_equal "done", command.handler.call("Klingon", context)
        assert_equal ["Hello Klingon"], output
        assert_equal "1 messages", registry.footer_renderer.call(context)
      end
    end
  end

  def test_plugin_paths_are_home_only_top_level_files
    Dir.mktmpdir do |home|
      plugins = File.join(home, ".kward", "plugins")
      nested = File.join(plugins, "nested")
      FileUtils.mkdir_p(nested)
      alpha = File.join(plugins, "alpha.rb")
      beta = File.join(plugins, "beta.rb")
      File.write(beta, "# beta\n")
      File.write(alpha, "# alpha\n")
      File.write(File.join(nested, "ignored.rb"), "# ignored\n")

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        assert_equal [alpha, beta], Kward::ConfigFiles.plugin_paths
      end
    end
  end

  def test_ignores_and_warns_about_config_path_plugins
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        legacy_plugins = File.join(config_dir, "plugins")
        FileUtils.mkdir_p(legacy_plugins)
        File.write(File.join(legacy_plugins, "legacy.rb"), <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command("legacy") { |_args, _ctx| "loaded" }
          end
        RUBY

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          _stdout, warnings = capture_io do
            registry = Kward::PluginRegistry.load
            assert_nil registry.command_for("legacy")
          end

          assert_includes warnings, "Warning: ignoring Kward plugins in #{legacy_plugins}"
          assert_includes warnings, "plugins are only loaded from #{File.join(home, ".kward", "plugins")}"
        end
      end
    end
  end

  def test_skips_reserved_and_duplicate_commands
    registry = Kward::PluginRegistry.new(reserved_commands: ["status"])

    _stderr, warnings = capture_io do
      registry.evaluate do |plugin|
        plugin.command("status") { |_args, _ctx| }
        plugin.command("demo") { |_args, _ctx| }
        plugin.command("demo") { |_args, _ctx| }
      end
    end

    assert_nil registry.command_for("status")
    assert registry.command_for("demo")
    assert_includes warnings, "reserved command"
    assert_includes warnings, "duplicate Kward plugin command /demo"
  end

  def test_transcript_messages_are_read_only_copies
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("hi")
    context = Kward::PluginRegistry::Context.new(conversation: conversation)
    messages = context.transcript.messages

    assert messages.frozen?
    assert messages.first.frozen?
    assert_raises(FrozenError) { messages.first[:content] = "changed" }
    assert_equal "hi", conversation.messages.first[:content]
  end

  def test_transcript_event_handlers_receive_read_only_event_payloads
    registry = Kward::PluginRegistry.new
    received = []
    registry.evaluate do |plugin|
      plugin.on_transcript_event do |event, ctx|
        received << [event, ctx.transcript.messages.length]
      end
    end
    conversation = Kward::Conversation.new(system_message: nil)
    conversation.append_user("hi")
    context = Kward::PluginRegistry::Context.new(conversation: conversation)

    registry.notify_transcript_event(Kward::Events::AssistantDelta.new(delta: "hello"), context)

    event, message_count = received.first
    assert_equal "assistant_delta", event.type
    assert_equal({ delta: "hello" }, event.payload)
    assert_equal 1, message_count
    assert event.frozen?
    assert event.payload.frozen?
    assert_raises(FrozenError) { event.payload[:delta] = "changed" }
  end
end
