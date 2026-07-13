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

        assert_equal [plugin_path], registry.paths
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

  def test_config_path_plugins_are_ignored_silently
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |config_dir|
        config_plugins = File.join(config_dir, "plugins")
        FileUtils.mkdir_p(config_plugins)
        File.write(File.join(config_plugins, "old.rb"), <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command("old") { |_args, _ctx| "loaded" }
          end
        RUBY

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => File.join(config_dir, "config.json")) do
          _stdout, warnings = capture_io do
            registry = Kward::PluginRegistry.load
            assert_nil registry.command_for("old")
          end

          assert_equal "", warnings
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

  def test_plugin_can_register_lifecycle_hook
    registry = Kward::PluginRegistry.new
    received = []

    registry.evaluate do |plugin|
      plugin.hook "shell_command_before", id: "block-release", description: "Block releases", order: 5, match: { command_regex: "gem push" } do |event, ctx|
        received << [event.name, event.payload[:command], ctx.workspace_root]
        ctx.deny("No releases today")
      end
    end

    hook = registry.hook_handlers.first
    assert_equal "shell_command_before", hook.event
    assert_equal "block-release", hook.id
    assert_equal "Block releases", hook.description
    assert_equal 5, hook.order

    conversation = Kward::Conversation.new(system_message: nil)
    context = Kward::PluginRegistry::Context.new(conversation: conversation, workspace_root: "/tmp/project")
    result = registry.hook_manager.run(Kward::Hooks::Event.new(
      name: "shell_command_before",
      payload: { command: "gem push kward.gem" }
    ), context: context)

    assert result.denied?
    assert_equal "No releases today", result.decision.message
    assert_equal [["shell_command_before", "gem push kward.gem", "/tmp/project"]], received
  end

  def test_plugin_context_decision_helpers
    context = Kward::PluginRegistry::Context.new(conversation: Kward::Conversation.new(system_message: nil))

    assert context.allow.allow?
    assert context.deny("stop").deny?
    assert context.ask("confirm").ask?
    assert context.modify({ timeout_seconds: 10 }).modify?
    assert context.warn("careful").warning?
  end

  def test_plugin_context_can_refresh_system_message
    conversation = Kward::Conversation.new
    original_content = conversation.system_message[:content]
    refreshed = false
    conversation.define_singleton_method(:refresh_system_message!) do
      refreshed = true
      { role: "system", content: "refreshed" }
    end
    context = Kward::PluginRegistry::Context.new(conversation: conversation)

    assert_nil context.refresh_system_message!
    assert refreshed
    assert_equal original_content, conversation.system_message[:content]
  end

  def test_prompt_context_renderers_are_joined
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.prompt_context { |_ctx| "First context." }
      plugin.prompt_context { |_ctx| "" }
      plugin.prompt_context { |_ctx| "Second context." }
    end
    context = Kward::PluginRegistry::Context.new(conversation: Kward::Conversation.new(system_message: nil))

    assert_equal "First context.\n\nSecond context.", registry.prompt_context(context)
  end

  def test_plugin_can_register_news_command
    registry = Kward::PluginRegistry.new(reserved_commands: Kward::PromptCommands::BUILTIN_RESERVED_COMMAND_NAMES)

    registry.evaluate do |plugin|
      plugin.command("news") { |_args, _ctx| "ok" }
    end

    assert registry.command_for("news")
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

  def test_transcript_event_handlers_receive_payloadless_events
    registry = Kward::PluginRegistry.new
    received = []
    registry.evaluate do |plugin|
      plugin.on_transcript_event do |event, _ctx|
        received << event
      end
    end
    context = Kward::PluginRegistry::Context.new(conversation: Kward::Conversation.new(system_message: nil))

    registry.notify_transcript_event(Kward::Events::ReasoningBoundary.new, context)

    assert_equal 1, received.length
    assert_equal "reasoning_boundary", received.first.type
    assert_equal({}, received.first.payload)
  end

  def test_registers_plugin_tab_type
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "example", id: "example.chat", title: "Example", singleton: :global do |host, descriptor|
        [host, descriptor]
      end
    end

    tab_type = registry.tab_type_for("example")
    assert_equal "example.chat", tab_type.id
    assert_equal "Example", tab_type.title
    assert_equal :global, tab_type.singleton
    refute tab_type.rpc
    assert_same tab_type, registry.tab_type_for_id("example.chat")
  end

  def test_registers_interactive_command
    registry = Kward::PluginRegistry.new

    registry.evaluate do |plugin|
      plugin.interactive_command "demo", rows: 10, fps: 60, description: "Demo canvas" do |ui, ctx|
        ui.put(0, 0, "X", :red)
      end
    end

    command = registry.interactive_command_for("demo")
    assert command
    assert_equal "demo", command.name
    assert_equal "Demo canvas", command.description
    assert_equal 10, command.rows
    assert_equal 60.0, command.fps
    assert_kind_of Proc, command.handler
  end

  def test_interactive_command_appears_in_entries
    registry = Kward::PluginRegistry.new

    registry.evaluate do |plugin|
      plugin.interactive_command "demo", rows: 5 do |ui, ctx| end
    end

    entries = registry.interactive_commands.map(&:entry)
    assert entries.any? { |entry| entry[:name] == "demo" }
  end

  def test_interactive_command_rejects_reserved_names
    registry = Kward::PluginRegistry.new(reserved_commands: ["status"])

    _stderr, warnings = capture_io do
      registry.evaluate do |plugin|
        plugin.interactive_command "status", rows: 5 do |ui, ctx| end
      end
    end

    assert_nil registry.interactive_command_for("status")
    assert_includes warnings, "reserved command"
  end

  def test_interactive_command_rejects_duplicates
    registry = Kward::PluginRegistry.new

    _stderr, warnings = capture_io do
      registry.evaluate do |plugin|
        plugin.interactive_command "demo", rows: 5 do |ui, ctx| end
        plugin.interactive_command "demo", rows: 5 do |ui, ctx| end
      end
    end

    assert registry.interactive_command_for("demo")
    assert_includes warnings, "duplicate Kward interactive command /demo"
  end

  def test_interactive_command_rejects_name_collision_with_regular_command
    registry = Kward::PluginRegistry.new

    _stderr, warnings = capture_io do
      registry.evaluate do |plugin|
        plugin.command("demo") { |_args, _ctx| }
        plugin.interactive_command "demo", rows: 5 do |ui, ctx| end
      end
    end

    assert_nil registry.interactive_command_for("demo")
    assert_includes warnings, "reserved command"
  end

  def test_interactive_command_clamps_rows_and_fps
    registry = Kward::PluginRegistry.new

    registry.evaluate do |plugin|
      plugin.interactive_command "demo", rows: -5, fps: 999 do |ui, ctx| end
    end

    command = registry.interactive_command_for("demo")
    assert_equal 1, command.rows
    assert_equal 120, command.fps
  end

  def test_interactive_command_handler_receives_controller_and_context
    registry = Kward::PluginRegistry.new
    received_ui = nil
    received_ctx = nil

    registry.evaluate do |plugin|
      plugin.interactive_command "demo", rows: 3 do |ui, ctx|
        received_ui = ui
        received_ctx = ctx
      end
    end

    command = registry.interactive_command_for("demo")
    conversation = Kward::Conversation.new(system_message: nil)
    context = Kward::PluginRegistry::Context.new(conversation: conversation)
    fake_controller = Object.new

    command.handler.call(fake_controller, context)

    assert_same fake_controller, received_ui
    assert_same context, received_ctx
  end
end
