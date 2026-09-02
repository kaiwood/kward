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

  def test_registers_stable_plugin_identity_and_shared_host
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump(
        "plugins" => {
          "com.example.demo" => { "endpoint" => "https://example.test" }
        }
      ))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        registry = Kward::PluginRegistry.new
        captured_host = nil

        registry.evaluate(path: "/plugins/demo.rb", id: "com.example.demo", version: "2.3.4", api: 1) do |plugin|
          captured_host = plugin.host
          plugin.command("host-id") { |_args, _ctx| plugin.host.id }
        end

        assert_same captured_host, registry.plugin_for("com.example.demo")
        assert_equal [captured_host], registry.plugins
        assert_equal "2.3.4", captured_host.version
        assert_equal "https://example.test", captured_host.config["endpoint"]
        assert_equal "com.example.demo", registry.command_for("host-id").handler.call(nil, nil)
      end
    end
  end

  def test_legacy_plugin_remains_supported_without_managed_host
    registry = Kward::PluginRegistry.new
    host = :unset

    registry.evaluate do |plugin|
      host = plugin.host
      plugin.command("legacy") { "ok" }
    end

    assert_nil host
    assert_empty registry.plugins
    assert registry.command_for("legacy")
  end

  def test_rejects_incomplete_unsupported_and_duplicate_plugin_identity
    registry = Kward::PluginRegistry.new

    incomplete = assert_raises(ArgumentError) do
      registry.evaluate(id: "com.example.demo", version: "1.0.0") { }
    end
    assert_includes incomplete.message, "id, version, and api are required together"

    unsupported = assert_raises(ArgumentError) do
      registry.evaluate(id: "com.example.demo", version: "1.0.0", api: 2) { }
    end
    assert_includes unsupported.message, "Unsupported Kward plugin API"

    registry.evaluate(id: "com.example.demo", version: "1.0.0", api: 1) { }
    duplicate = assert_raises(ArgumentError) do
      registry.evaluate(id: "com.example.demo", version: "1.0.1", api: 1) { }
    end
    assert_includes duplicate.message, "Duplicate Kward plugin id"
  end

  def test_loads_identified_plugin_from_entrypoint
    Dir.mktmpdir do |home|
      plugins = File.join(home, ".kward", "plugins")
      FileUtils.mkdir_p(plugins)
      plugin_path = File.join(plugins, "identified.rb")
      File.write(plugin_path, <<~'RUBY')
        Kward.plugin(id: "com.example.loaded", version: "1.0.0", api: 1) do |plugin|
          plugin.command("loaded-host") { plugin.host.id }
        end
      RUBY

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        registry = Kward::PluginRegistry.load

        assert_equal "com.example.loaded", registry.plugins.first.id
        assert_equal plugin_path, registry.plugins.first.source_path
        assert_equal "com.example.loaded", registry.command_for("loaded-host").handler.call
      end
    end
  end

  def test_shipped_plugin_examples_declare_stable_identity
    examples = [
      File.expand_path("../examples/plugins/stardate_footer.rb", __dir__),
      File.expand_path("../examples/plugins/space_invaders.rb", __dir__),
      File.expand_path("../examples/plugins/telegram/plugin.rb", __dir__)
    ]

    registry = Kward::PluginRegistry.load(paths: examples)

    assert_equal [
      "com.kward.example.stardate-footer",
      "com.kward.example.space-invaders",
      "com.kward.telegram"
    ], registry.plugins.map(&:id)
    assert registry.plugins.all? { |plugin| plugin.version == "1.0.0" }
    assert registry.plugins.all? { |plugin| plugin.api_version == Kward::PluginRegistry::PLUGIN_API_VERSION }
  end

  def test_plugin_paths_are_home_only_files_and_package_entrypoints
    Dir.mktmpdir do |home|
      plugins = File.join(home, ".kward", "plugins")
      nested = File.join(plugins, "nested")
      FileUtils.mkdir_p(nested)
      alpha = File.join(plugins, "alpha.rb")
      beta = File.join(plugins, "beta.rb")
      File.write(beta, "# beta\n")
      File.write(alpha, "# alpha\n")
      File.write(File.join(nested, "ignored.rb"), "# ignored\n")
      package = File.join(nested, "plugin.rb")
      File.write(package, "# package\n")

      with_env("HOME" => home, "KWARD_CONFIG_PATH" => nil) do
        assert_equal [alpha, beta, package], Kward::ConfigFiles.plugin_paths
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

  def test_warnings_use_the_configured_sink
    warnings = []
    registry = Kward::PluginRegistry.new(reserved_commands: ["status"], warning_sink: warnings.method(:<<))

    _stdout, stderr = capture_io do
      registry.evaluate do |plugin|
        plugin.command("status") { |_args, _ctx| }
        plugin.command("demo") { |_args, _ctx| }
        plugin.command("demo") { |_args, _ctx| }
      end
    end

    assert_empty stderr
    assert_includes warnings, "Warning: skipping Kward plugin command /status: reserved command"
    assert warnings.any? { |warning| warning.start_with?("Warning: skipping duplicate Kward plugin command /demo") }
  end

  def test_registers_transport_with_normalized_capabilities
    registry = Kward::PluginRegistry.new
    handler = proc { |_host, _config| :transport }
    profile = Kward::Transport.execution_profile(id: "isolated_chat", tool_mode: :none)

    registry.evaluate do |plugin|
      plugin.transport "demo", id: "com.example.demo", capabilities: { inbound: [:text], streaming: :aggregate }, execution_profile: profile, &handler
    end

    transport = registry.transport_for("demo")
    assert_equal "com.example.demo", transport.id
    assert_equal [:text], transport.capabilities.inbound
    assert_equal :aggregate, transport.capabilities.streaming
    assert_equal profile, transport.execution_profile
    assert_same handler, transport.handler
    assert_same transport, registry.transport_for_id("com.example.demo")
  end

  def test_skips_duplicate_transport_names_and_ids
    registry = Kward::PluginRegistry.new

    _stderr, warnings = capture_io do
      registry.evaluate do |plugin|
        plugin.transport("demo", id: "com.example.demo") { nil }
        plugin.transport("demo", id: "com.example.other") { nil }
        plugin.transport("other", id: "com.example.demo") { nil }
      end
    end

    assert_equal 1, registry.transports.length
    assert_includes warnings, "duplicate Kward plugin transport"
  end

  def test_rejects_invalid_transport_registration
    registry = Kward::PluginRegistry.new

    assert_raises(RuntimeError) do
      registry.evaluate { |plugin| plugin.transport("bad name", id: "com.example.bad") { nil } }
    end
    assert_raises(RuntimeError) do
      registry.evaluate { |plugin| plugin.transport("missing-handler", id: "com.example.missing") }
    end
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

  def test_registers_model_callable_tool
    registry = Kward::PluginRegistry.new

    registry.evaluate(path: "/plugins/issues.rb") do |plugin|
      plugin.tool "issue_search", description: "Search issues", schema: {
        type: "object",
        properties: {
          limit: { type: "integer" },
          query: { type: "string" }
        },
        required: ["query"]
      } do |args, ctx|
        "#{ctx.workspace_root}:#{args.fetch("query")}"
      end
    end

    tool = registry.tool_for("issue_search")

    assert_equal [tool], registry.tools
    assert_equal "Search issues", tool.description
    assert_equal "/plugins/issues.rb", tool.path
    assert_equal %i[limit query], tool.schema.fetch(:properties).keys
    assert_equal ["query"], tool.schema.fetch(:required)
    assert_equal false, tool.schema.fetch(:additionalProperties)
    assert tool.schema.frozen?
  end

  def test_skips_duplicate_plugin_tools
    warnings = []
    registry = Kward::PluginRegistry.new(warning_sink: ->(message) { warnings << message })

    registry.evaluate do |plugin|
      2.times do
        plugin.tool("lookup", description: "Look up a value") { "ok" }
      end
    end

    assert_equal 1, registry.tools.length
    assert_includes warnings.join("\n"), "duplicate Kward plugin tool lookup"
  end

  def test_rejects_invalid_plugin_tool_schemas
    registry = Kward::PluginRegistry.new

    error = assert_raises(ArgumentError) do
      registry.evaluate do |plugin|
        plugin.tool "lookup", description: "Look up a value", schema: {
          type: "object",
          properties: {},
          required: ["missing"]
        } do
          "ok"
        end
      end
    end

    assert_includes error.message, "requires unknown properties: missing"
  end

  def test_registers_typed_command_with_shell_style_arguments
    registry = Kward::PluginRegistry.new
    received = nil

    registry.evaluate(id: "com.example.release", version: "1.0.0", api: "1") do |plugin|
      plugin.command "deploy",
        description: "Deploy a service",
        schema: {
          type: "object",
          properties: {
            service: { type: "string" },
            environment: { type: "string", enum: %w[staging production], default: "staging" },
            dry_run: { type: "boolean", default: false },
            retries: { type: "integer", default: 1 },
            labels: { type: "array", items: { type: "string" } }
          },
          required: ["service"]
        },
        positionals: ["service"] do |args, ctx|
          received = [args, ctx.args]
          ctx.result(message: "Queued", data: { deployment_id: 42 })
        end
    end

    command = registry.command_for("deploy")
    arguments = command.parse_arguments("api --environment production --dry-run --retries 3 --labels urgent --labels 'release candidate'")
    context = Kward::PluginRegistry::Context.new(conversation: Kward::Conversation.new(system_message: nil), args: arguments)
    result = command.normalize_result(command.handler.call(arguments, context))

    assert command.typed?
    assert_equal "com.example.release", command.plugin_id
    assert_equal ["service"], command.positionals
    assert_equal({
      "service" => "api",
      "environment" => "production",
      "dry_run" => true,
      "retries" => 3,
      "labels" => ["urgent", "release candidate"]
    }, arguments)
    assert_equal [arguments, arguments], received
    assert_equal({ message: "Queued", data: { "deployment_id" => 42 } }, result.to_h)
    assert_equal false, command.parse_arguments("api --no-dry-run").fetch("dry_run")
    assert command.schema.frozen?
  end

  def test_typed_command_rejects_unknown_missing_and_invalid_arguments
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.command "deploy", schema: {
        type: "object",
        properties: {
          environment: { type: "string", enum: %w[staging production] },
          force: { type: "boolean" }
        },
        required: ["environment"]
      } do |_args, _ctx|
        "unused"
      end
    end
    command = registry.command_for("deploy")

    assert_includes assert_raises(ArgumentError) { command.parse_arguments("--unknown value") }.message, "unknown option"
    assert_includes assert_raises(ArgumentError) { command.parse_arguments("") }.message, "missing required arguments"
    assert_includes assert_raises(ArgumentError) { command.parse_arguments("--environment test") }.message, "must be one of"
    assert_includes assert_raises(ArgumentError) { command.parse_arguments({ environment: "staging", force: "yes" }) }.message, "force must be boolean"
  end

  def test_legacy_command_keeps_raw_string_arguments
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.command("legacy") { |args| args }
    end

    command = registry.command_for("legacy")

    refute command.typed?
    assert_equal "--still raw", command.parse_arguments("--still raw")
    assert_equal "done", command.normalize_result("done")
  end

  def test_registers_namespaced_plugin_action_and_requires_identity
    registry = Kward::PluginRegistry.new
    registry.evaluate(id: "com.example.release", version: "1.0.0", api: "1") do |plugin|
      plugin.action "status", description: "Read release status", schema: {
        type: "object",
        properties: { deployment_id: { type: "integer" } },
        required: ["deployment_id"]
      } do |args, ctx|
        ctx.result(data: { deployment_id: args.fetch("deployment_id"), state: "ready" })
      end
    end

    action = registry.action_for("com.example.release/status")
    arguments = action.parse_arguments(deployment_id: 42)
    context = Kward::PluginRegistry::Context.new(conversation: Kward::Conversation.new(system_message: nil), args: arguments)
    result = action.normalize_result(action.handler.call(arguments, context))

    assert_equal [action], registry.actions
    assert_equal "com.example.release", action.plugin_id
    assert_equal({ data: { "deployment_id" => 42, "state" => "ready" } }, result.to_h)
    assert_includes assert_raises(ArgumentError) { action.parse_arguments("--deployment-id 42") }.message, "must be an object"

    error = assert_raises(ArgumentError) do
      registry.evaluate { |plugin| plugin.action("broken", description: "Broken") { nil } }
    end
    assert_includes error.message, "require stable plugin identity"
  end

  def test_registers_plugin_tab_type
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "example", id: "example.chat", title: "Example", singleton: :global, transport: true, transcript_events: true do |host, descriptor|
        [host, descriptor]
      end
    end

    tab_type = registry.tab_type_for("example")
    assert_equal "example.chat", tab_type.id
    assert_equal "Example", tab_type.title
    assert_equal :global, tab_type.singleton
    refute tab_type.rpc
    assert tab_type.transport
    assert tab_type.local
    assert_equal [tab_type], registry.transport_tab_types
    assert tab_type.transcript_events
    assert_same tab_type, registry.tab_type_for_id("example.chat")
  end

  def test_registers_transport_only_tab_type
    registry = Kward::PluginRegistry.new
    registry.evaluate do |plugin|
      plugin.tab_type "telegram", id: "com.example.telegram", local: false, transport: true do |host, descriptor|
        [host, descriptor]
      end
    end

    tab_type = registry.tab_type_for("telegram")
    refute tab_type.local
    assert tab_type.transport
    assert_equal [tab_type], registry.transport_tab_types
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
