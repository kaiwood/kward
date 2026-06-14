require_relative "test_support"

class TestRPCServer < KwardTestCase
  include KwardRPCTestSupport

  def test_initialize_reports_native_steering_when_client_supports_it
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "initialize" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ], client: SteeringClient.new)

    capabilities = messages[0]["result"]["capabilities"]
    assert_equal "native", capabilities["turns"]["busyInput"]["steer"]
    assert_equal "steer", capabilities["turns"]["busyInput"]["defaultWhenBusy"]
    assert_equal true, capabilities["events"]["steering"]["supported"]
    assert_equal "native", capabilities["events"]["steering"]["mode"]
  end

  def test_initialize_reports_auto_resume_enabled_config
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => true }))
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "initialize" },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      capabilities = messages[0]["result"]["capabilities"]
      assert_equal true, capabilities["sessions"].dig("startupResume", "default")
    end
  end

  def test_initialize_reports_auto_resume_disabled_config
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump("sessions" => { "auto_resume" => false }))
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "initialize" },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      capabilities = messages[0]["result"]["capabilities"]
      assert_equal false, capabilities["sessions"].dig("startupResume", "default")
    end
  end

  def test_initialize_and_shutdown
    config_dir = Dir.mktmpdir
    config_path = File.join(config_dir, "config.json")
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "initialize" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ], env: { "KWARD_CONFIG_PATH" => config_path })

    assert_equal 1, messages[0]["result"]["protocolVersion"]
    capabilities = messages[0]["result"]["capabilities"]
    assert_equal "content-length", capabilities["framing"]

    detailed_groups = %w[transcript sessions turns events attachments models runtime runtimeSettings auth commands startupResources extensionUi composer security export logging]
    detailed_groups.each { |group| assert capabilities.key?(group), "missing capability group #{group}" }

    assert_equal "tauren-transcript-v1", capabilities["transcript"]["format"]
    assert_equal true, capabilities["transcript"]["messagesNormalized"]
    assert_equal true, capabilities["transcript"]["supportsCompactionSummaries"]
    assert_equal true, capabilities["transcript"]["supportsReasoningRestore"]
    assert_equal "explicit", capabilities["sessions"]["mode"]
    assert_equal "jsonl", capabilities["sessions"]["persistence"]
    assert_equal ["sessions/create", "sessions/resume", "sessions/list", "sessions/rename", "sessions/clone", "sessions/compact", "sessions/forkMessages", "sessions/fork", "sessions/tree", "sessions/tree/setLabel", "sessions/tree/navigate", "sessions/export", "sessions/delete", "sessions/close", "sessions/transcript"], capabilities["sessions"]["methods"]
    assert_equal true, capabilities["sessions"].dig("startupResume", "supported")
    assert_equal false, capabilities["sessions"].dig("startupResume", "default")
    assert_equal "resumeLast", capabilities["sessions"].dig("startupResume", "parameter")
    assert_equal true, capabilities["sessions"].dig("startupResume", "immediateTranscript")
    assert_equal true, capabilities["sessions"].dig("startupResume", "sessionActivePersonaLabel")
    assert_equal true, capabilities["sessions"]["list"]["supported"]
    assert_equal true, capabilities["sessions"]["list"]["ancestry"]
    assert_equal true, capabilities["sessions"]["list"]["treeFields"]
    assert_equal true, capabilities["sessions"]["fork"]["supported"]
    assert_equal ["sessions/forkMessages", "sessions/fork"], capabilities["sessions"]["fork"]["methods"]
    assert_equal true, capabilities["sessions"]["compact"]["supported"]
    assert_equal "sessions/compact", capabilities["sessions"]["compact"]["method"]
    assert_equal false, capabilities["sessions"]["import"]["supported"]
    assert_equal true, capabilities["sessions"]["tree"]["supported"]
    assert_equal true, capabilities["sessions"]["tree"]["labels"]
    assert_equal true, capabilities["sessions"]["tree"]["navigate"]
    assert_equal false, capabilities["sessions"]["updates"]["supported"]
    assert_equal "async", capabilities["turns"]["mode"]
    assert_equal 1, capabilities["turns"]["perSessionConcurrency"]
    assert_equal "unsupported", capabilities["turns"]["busyInput"]["steer"]
    assert_equal "queue", capabilities["turns"]["busyInput"]["followUp"]
    assert_equal "newTurn", capabilities["turns"]["busyInput"]["defaultWhenIdle"]
    assert_equal "followUp", capabilities["turns"]["busyInput"]["defaultWhenBusy"]
    assert_equal "best-effort", capabilities["turns"]["cancellation"]["behavior"]
    assert_equal false, capabilities["turns"]["eventReplay"]["persisted"]
    assert_equal 1000, capabilities["turns"]["eventReplay"]["limit"]
    assert_equal "turn/event", capabilities["events"]["notification"]
    assert_equal false, capabilities["events"]["steering"]["supported"]
    assert_equal "turnSteered", capabilities["events"]["steering"]["event"]
    assert_equal true, capabilities["events"]["tools"]["normalizedMetadata"]
    assert_equal true, capabilities["events"]["tools"]["diffs"]
    assert_equal false, capabilities["events"]["tools"]["changedFiles"]
    assert_equal false, capabilities["events"]["sessionUpdates"]
    assert_equal true, capabilities["attachments"]["input"]["supported"]
    assert_equal Kward::RPC::SessionManager::RPC_IMAGE_MIME_TYPES, capabilities["attachments"]["input"]["mimeTypes"]
    assert_equal Kward::RPC::SessionManager::RPC_ATTACHMENT_MAX_BYTES, capabilities["attachments"]["input"]["maxBytes"]
    assert_includes capabilities["models"]["methods"], "models/set"
    assert_includes capabilities["models"]["methods"], "openrouter/catalog"
    assert_equal false, capabilities["models"]["scopedModels"]
    assert_equal true, capabilities["runtime"]["supported"]
    assert_equal ["runtime/state", "runtime/stats"], capabilities["runtime"]["methods"]
    assert_equal true, capabilities["runtime"]["stats"]["messageCounts"]
    assert_equal true, capabilities["runtime"]["stats"]["contextUsage"]
    assert_equal true, capabilities["runtime"]["stats"]["contextUsageEstimated"]
    assert_equal true, capabilities["runtimeSettings"]["supported"]
    assert_equal ["runtime/updateSetting", "runtime/reload"], capabilities["runtimeSettings"]["methods"]
    assert_equal ["defaultModel", "defaultThinkingLevel"], capabilities["runtimeSettings"]["settings"]
    assert_equal true, capabilities["auth"]["supported"]
    assert_equal "tauren-auth-v1", capabilities["auth"]["providerFormat"]
    assert_equal ["openai", "github"], capabilities["auth"]["oauthProviders"]
    assert_equal "CLI-only GitHub login for Copilot scaffolding; RPC login is not implemented yet.", capabilities["auth"].dig("unsupportedOAuthProviders", "github")
    assert_equal ["openrouter"], capabilities["auth"]["apiKeyProviders"]
    assert_equal true, capabilities["auth"]["logout"]
    assert_includes capabilities["auth"]["methods"], "auth/providers"
    assert_includes capabilities["auth"]["methods"], "auth/loginWithApiKey"
    assert_includes capabilities["auth"]["methods"], "auth/logoutProvider"
    assert_includes capabilities["auth"]["methods"], "auth/loginWithOAuth"
    assert_equal true, capabilities["memory"]["supported"]
    assert_equal false, capabilities["memory"]["autoSummaryDefaultEnabled"]
    assert_includes capabilities["memory"]["methods"], "memory/autoSummary/enable"
    assert_includes capabilities["memory"]["methods"], "memory/autoSummary/disable"
    assert_includes capabilities["memory"]["methods"], "memory/relax"
    assert_equal true, capabilities["commands"]["supported"]
    assert_equal ["builtin", "prompt", "skill", "plugin"], capabilities["commands"]["sources"]
    assert_equal ["builtin", "plugin"], capabilities["commands"]["executableSources"]
    assert_equal "commands/run", capabilities["commands"]["runMethod"]
    assert_equal true, capabilities["startupResources"]["supported"]
    assert_equal false, capabilities.dig("starterPack", "supported")
    assert_equal "cliOnlyInstallCommand", capabilities.dig("starterPack", "reason")
    assert_equal({
      "question" => {
        "supported" => true,
        "notification" => "ui/question",
        "method" => "ui/answerQuestion",
        "maxQuestions" => 4,
        "multiSelect" => false,
        "preview" => false
      },
      "select" => false,
      "confirm" => false,
      "input" => false,
      "editor" => false,
      "widgets" => false,
      "footer" => {
        "supported" => true,
        "notification" => "ui/footer"
      },
      "custom" => false,
      "terminalInput" => false
    }, capabilities["extensionUi"])
    assert_equal false, capabilities.dig("composer", "sessionDiff", "supported")
    assert_equal "interactiveComposerOnly", capabilities.dig("composer", "sessionDiff", "reason")
    assert_equal false, capabilities.dig("composer", "copy", "supported")
    assert_equal "clientClipboardOwnedByUi", capabilities.dig("composer", "copy", "reason")
    assert_equal "none", capabilities["security"]["workspaceMutationGuard"]
    assert_equal "none", capabilities["security"]["toolApproval"]
    assert_equal ["markdown", "html"], capabilities["export"]["formats"]
    assert_equal true, capabilities["logging"]["supported"]
    assert_equal false, capabilities["logging"]["defaultEnabled"]
    assert_equal ["logging/stats", "logging/tokenCsv"], capabilities["logging"]["methods"]
    assert_equal "1 week", capabilities["logging"]["stats"]["defaultRange"]
    assert_equal true, capabilities["logging"]["usageCsv"]["supported"]
    assert_equal ["tokens", "performance", "tools", "errors"], capabilities["logging"]["categories"]
    assert_equal 10_485_760, capabilities["logging"]["rotation"]["maxBytes"]
    assert_equal "redacted-metadata-only", capabilities["logging"]["content"]

    refute capabilities.key?("asyncTurns")
    refute capabilities.key?("session")
    refute capabilities.key?("config")
    assert_equal true, messages[1]["result"]["ok"]
  ensure
    FileUtils.remove_entry(config_dir) if config_dir && Dir.exist?(config_dir)
  end

  def test_tools_list_matches_default_registry_tools
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "tools/list" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ])

    rpc_tool_names = messages[0]["result"]["tools"].map { |schema| schema["function"]["name"] }
    registry_tool_names = Kward::ToolRegistry.new(workspace: Kward::Workspace.new).schemas.map { |schema| schema[:function][:name] }

    assert_equal registry_tool_names, rpc_tool_names
  end

  def test_initialize_capability_method_lists_match_rpc_methods
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "initialize" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ])
    capabilities = messages[0]["result"]["capabilities"]

    assert_equal Kward::RPC::Server::MODEL_METHODS, capabilities["models"]["methods"]
    assert_equal ["runtime/state", "runtime/stats"], capabilities["runtime"]["methods"]
    assert_equal ["runtime/updateSetting", "runtime/reload"], capabilities["runtimeSettings"]["methods"]
    assert_equal Kward::RPC::Server::AUTH_METHODS, capabilities["auth"]["methods"]
    assert_equal ["logging/stats", "logging/tokenCsv"], capabilities["logging"]["methods"]
    assert_equal Kward::RPC::Server::MEMORY_METHODS, capabilities["memory"]["methods"]
    assert_equal "commands/list", capabilities["commands"]["method"]
    assert_includes capabilities["commands"]["methods"], "commands/run"
    assert_equal "resources/startup", capabilities["startupResources"]["method"]
    assert_equal Kward::RPC::Server::SESSION_METHODS, capabilities["sessions"]["methods"]
  end

  def test_unknown_rpc_method_returns_method_not_found
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "missing/method" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ])

    assert_equal(-32_601, messages[0]["error"]["code"])
    assert_equal "Method not found: missing/method", messages[0]["error"]["message"]
  end

  def test_memory_rpc_methods_manage_hierarchy
    Dir.mktmpdir do |dir|
      workspace_root = File.realpath(Dir.mktmpdir)
      other_workspace = File.realpath(Dir.mktmpdir)
      config_path = File.join(dir, "config.json")
      workspace_scope = "workspace:#{workspace_root}"
      other_scope = "workspace:#{other_workspace}"

      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "memory/enable" },
        { jsonrpc: "2.0", id: 2, method: "memory/status" },
        { jsonrpc: "2.0", id: 3, method: "memory/addCore", params: { text: "Use global workflow" } },
        { jsonrpc: "2.0", id: 4, method: "memory/addCore", params: { text: "Use workspace workflow", scope: workspace_scope } },
        { jsonrpc: "2.0", id: 5, method: "memory/add", params: { text: "Workspace prefers minitest", scope: workspace_scope, tags: ["workflow"] } },
        { jsonrpc: "2.0", id: 6, method: "memory/addCore", params: { text: "Use other workflow", scope: other_scope } },
        { jsonrpc: "2.0", id: 7, method: "memory/add", params: { text: "Other prefers rspec", scope: other_scope, tags: ["workflow"] } },
        { jsonrpc: "2.0", id: 8, method: "memory/list", params: { workspaceRoot: workspace_root } },
        { jsonrpc: "2.0", id: 9, method: "memory/promote", params: { id: "core_002" } },
        { jsonrpc: "2.0", id: 10, method: "memory/relax", params: { id: "core_002", workspaceRoot: workspace_root } },
        { jsonrpc: "2.0", id: 11, method: "memory/promote", params: { id: "soft_001" } },
        { jsonrpc: "2.0", id: 12, method: "memory/forget", params: { id: "core_004" } },
        { jsonrpc: "2.0", id: 13, method: "memory/inspect" },
        { jsonrpc: "2.0", id: 14, method: "memory/why" },
        { jsonrpc: "2.0", id: 15, method: "memory/disable" },
        { jsonrpc: "2.0", id: 16, method: "memory/status" },
        { jsonrpc: "2.0", id: 17, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })

      assert_empty messages.select { |message| message["error"] }
      assert_equal true, messages.find { |message| message["id"] == 2 }.dig("result", "enabled")

      hierarchy = messages.find { |message| message["id"] == 8 }["result"]
      assert_equal ["core_001"], hierarchy["global_core"].map { |item| item["id"] }
      assert_equal ["core_002"], hierarchy["workspace_core"].map { |item| item["id"] }
      assert_equal ["soft_001"], hierarchy["workspace_soft"].map { |item| item["id"] }

      assert_equal "global", messages.find { |message| message["id"] == 9 }.dig("result", "memory", "scope")
      assert_equal workspace_scope, messages.find { |message| message["id"] == 10 }.dig("result", "memory", "scope")
      assert_equal workspace_scope, messages.find { |message| message["id"] == 11 }.dig("result", "memory", "scope")
      assert_equal true, messages.find { |message| message["id"] == 12 }.dig("result", "forgotten")
      assert_equal "No memory retrieval has run yet.", messages.find { |message| message["id"] == 14 }.dig("result", "message")
      assert_equal false, messages.find { |message| message["id"] == 16 }.dig("result", "enabled")
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
      FileUtils.remove_entry(other_workspace) if other_workspace && File.exist?(other_workspace)
    end
  end

  def test_memory_summarize_rpc_route_learns_from_session
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      output = StringIO.new

      with_env("KWARD_CONFIG_PATH" => config_path) do
        server = Kward::RPC::Server.new(input: StringIO.new, output: output, error_output: StringIO.new, client: FakeClient.new([]))
        session = server.instance_variable_get(:@session_manager).create_session(workspace_root: Dir.pwd)
        rpc_session = server.instance_variable_get(:@session_manager).send(:fetch_session, session[:id])
        rpc_session.conversation.append_user("I prefer concise answers")
        server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 1, "method" => "memory/summarize", "params" => { "sessionId" => session[:id] } })
      end

      result = read_framed_messages(output).find { |message| message["id"] == 1 }["result"]
      assert_equal ["I prefer concise answers"], result["memories"].map { |memory| memory["text"] }
      assert_equal ["soft_001"], result["memories"].map { |memory| memory["id"] }
    end
  end

  def test_logging_stats_rpc_returns_structured_summary
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl"), JSON.generate("timestamp" => Time.now.utc.iso8601(3), "category" => "tokens", "event" => "model_usage", "usage" => { "total_tokens" => 11 }) + "\n")
      output = StringIO.new

      with_env("KWARD_CONFIG_PATH" => config_path) do
        server = Kward::RPC::Server.new(input: StringIO.new, output: output, error_output: StringIO.new, client: FakeClient.new([]))
        server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 1, "method" => "logging/stats", "params" => { "range" => "1 day" } })
      end

      message = read_framed_messages(output).first
      result = message["result"]
      assert_equal 1, result["recordCount"]
      assert_equal 11, result["usageStats"]["totals"]["total_tokens"]
      assert_equal ["tokens"], result["enabledCategories"]
    end
  end

  def test_logging_stats_rpc_rejects_invalid_range
    output = StringIO.new
    server = Kward::RPC::Server.new(input: StringIO.new, output: output, error_output: StringIO.new, client: FakeClient.new([]))

    with_env("KWARD_LOGGING" => "true", "KWARD_LOGGING_TOKENS" => "true") do
      server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 1, "method" => "logging/stats", "params" => { "range" => "banana" } })
    end

    message = read_framed_messages(output).first
    assert_equal(-32_602, message["error"]["code"])
    assert_includes message["error"]["message"], Kward::TelemetryStats::USAGE
  end

  def test_logging_token_csv_rpc_returns_csv
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.json")
      File.write(config_path, JSON.dump("logging" => { "enabled" => true, "tokens" => true }))
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl"), JSON.generate("timestamp" => Time.now.utc.iso8601(3), "category" => "tokens", "event" => "model_usage", "provider" => "openrouter", "model" => "alpha", "usage" => { "total_tokens" => 11 }) + "\n")
      output = StringIO.new

      with_env("KWARD_CONFIG_PATH" => config_path) do
        server = Kward::RPC::Server.new(input: StringIO.new, output: output, error_output: StringIO.new, client: FakeClient.new([]))
        server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 1, "method" => "logging/tokenCsv", "params" => { "range" => "5 hours", "bucket" => "hour" } })
      end

      csv = read_framed_messages(output).first["result"]["csv"]
      assert_includes csv, "bucket_start,bucket_end,provider,model,events,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,total_tokens"
      assert_includes csv, "openrouter,alpha,1,0,0,0,0,11"
    end
  end

  def test_turn_start_rpc_invalid_params_for_attachments_and_streaming_behavior
    output = StringIO.new
    server = Kward::RPC::Server.new(input: StringIO.new, output: output, error_output: StringIO.new, client: FakeClient.new([]))
    session = server.instance_variable_get(:@session_manager).create_session(workspace_root: Dir.pwd)

    server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 1, "method" => "turns/start", "params" => { "sessionId" => session[:id], "input" => "bad", "attachments" => [{ "type" => "image", "data" => "YQ==", "mimeType" => "image/svg+xml" }] } })
    server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 2, "method" => "turns/start", "params" => { "sessionId" => session[:id], "input" => "large", "attachments" => [{ "type" => "image", "data" => "YQ==", "mimeType" => "image/png", "sizeBytes" => Kward::RPC::SessionManager::RPC_ATTACHMENT_MAX_BYTES + 1 }] } })
    server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 3, "method" => "turns/start", "params" => { "sessionId" => session[:id], "input" => "steer", "streamingBehavior" => "steer" } })

    errors = read_framed_messages(output).select { |message| message["error"] }
    assert_equal [-32_602, -32_602, -32_602], errors.map { |message| message["error"]["code"] }
    assert_equal "Unsupported image MIME type: image/svg+xml", errors[0]["error"]["message"]
    assert_equal "Image attachment is too large", errors[1]["error"]["message"]
    assert_equal "Unsupported streamingBehavior: steer", errors[2]["error"]["message"]
  end

  def test_commands_list_and_startup_resources_return_prompts_and_skills
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |home|
        config_path = File.join(config_dir, "config.json")
        prompts_dir = File.join(config_dir, "prompts")
        skill_dir = File.join(config_dir, "skills", "testing-verification")
        plugins_dir = File.join(home, ".kward", "plugins")
        FileUtils.mkdir_p(prompts_dir)
        FileUtils.mkdir_p(skill_dir)
        FileUtils.mkdir_p(plugins_dir)
        File.write(File.join(config_dir, "AGENTS.md"), "# Context\n")
        File.write(File.join(prompts_dir, "review.md"), "---\ndescription: Review current changes\nargument-hint: files\n---\nReview $ARGUMENTS\n")
        File.write(File.join(skill_dir, "SKILL.md"), "---\nname: testing-verification\ndescription: Testing and verification guidance\n---\n# Skill\n")
        File.write(File.join(plugins_dir, "hello.rb"), <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command "hello", description: "Say hello", argument_hint: "<name>" do |args, ctx|
              ctx.say("Hello #{args}; messages=#{ctx.transcript.messages.length}")
              "returned #{args}"
            end
          end
        RUBY

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => config_path) do
          server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: FakeClient.new([]))
          session = server.instance_variable_get(:@session_manager).create_session(workspace_root: Dir.pwd)

          commands = server.send(:commands_list, "sessionId" => session[:id])[:commands]
          prompt = commands.find { |command| command[:source] == "prompt" }
          skill = commands.find { |command| command[:source] == "skill" }
          assert_equal "review", prompt[:name]
          assert_equal "Review current changes", prompt[:description]
          assert_equal File.join(prompts_dir, "review.md"), prompt[:path]
          assert_equal "skill:testing-verification", skill[:name]
          assert_equal "Testing and verification guidance", skill[:description]
          assert_equal File.join(skill_dir, "SKILL.md"), skill[:path]
          copy_command = commands.find { |command| command[:name] == "copy" }
          assert_equal false, copy_command[:executable]
          assert_equal true, copy_command[:unsupported]
          assert_equal "clientClipboardOwnedByUi", copy_command[:reason]
          plugin = commands.find { |command| command[:source] == "plugin" }
          assert_equal "hello", plugin[:name]
          assert_equal "Say hello", plugin[:description]
          assert_equal "<name>", plugin[:argumentHint]
          assert_equal true, plugin[:executable]

          run = server.send(:commands_run, "sessionId" => session[:id], "name" => "hello", "arguments" => "Martok")
          assert_equal "hello", run[:command]
          assert_equal ["Hello Martok; messages=1"], run[:output]
          assert_equal "returned Martok", run[:result]

          sections = server.send(:startup_resources, "sessionId" => session[:id])[:sections]
          assert_equal ["AGENTS.md"], sections.find { |section| section[:name] == "Context" }[:items]
          assert_equal ["testing-verification"], sections.find { |section| section[:name] == "Skills" }[:items]
          assert_equal ["/review"], sections.find { |section| section[:name] == "Prompts" }[:items]
          assert_equal ["/hello"], sections.find { |section| section[:name] == "Plugins" }[:items]
        end
      end
    end
  end

  def test_runtime_reload_reloads_plugins_for_active_sessions
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |home|
        config_path = File.join(config_dir, "config.json")
        plugins_dir = File.join(home, ".kward", "plugins")
        plugin_path = File.join(plugins_dir, "version.rb")
        FileUtils.mkdir_p(plugins_dir)
        File.write(plugin_path, <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command "version" do |_args, ctx|
              ctx.say("plugin=v1")
            end
            plugin.prompt_context do |_ctx|
              "Plugin context: v1"
            end
          end
        RUBY

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => config_path) do
          server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: FakeClient.new([]))
          manager = server.instance_variable_get(:@session_manager)
          session = manager.create_session(workspace_root: Dir.pwd)

          first_run = server.send(:commands_run, "sessionId" => session[:id], "name" => "version")
          File.write(plugin_path, <<~'RUBY')
            Kward.plugin do |plugin|
              plugin.command "version" do |_args, ctx|
                ctx.say("plugin=v2")
              end
              plugin.prompt_context do |_ctx|
                "Plugin context: v2"
              end
            end
          RUBY
          reload = server.send(:runtime_reload, "sessionId" => session[:id])
          second_run = server.send(:commands_run, "sessionId" => session[:id], "name" => "version")
          conversation = manager.send(:fetch_session, session[:id]).conversation
          system_message = conversation.messages.find { |message| Kward::MessageAccess.role(message) == "system" }

          assert_equal ["plugin=v1"], first_run[:output]
          assert_equal({ ok: true, message: "Resources reloaded." }, reload)
          assert_equal ["plugin=v2"], second_run[:output]
          assert_includes Kward::MessageAccess.content(system_message), "Plugin context: v2"
          refute_includes Kward::MessageAccess.content(system_message), "Plugin context: v1"
        end
      end
    end
  end

  def test_commands_run_reports_copy_unsupported
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({}))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        server = Kward::RPC::Server.new(input: StringIO.new, output: StringIO.new, error_output: StringIO.new, client: FakeClient.new([]))
        session = server.instance_variable_get(:@session_manager).create_session(workspace_root: Dir.pwd)
        result = server.send(:commands_run, "sessionId" => session[:id], "name" => "copy")

        assert_equal false, result[:ok]
        assert_equal "unsupported", result[:error]
        assert_equal "clientClipboardOwnedByUi", result[:reason]
      end
    end
  end

  def test_rpc_shutdown_deletes_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      workspace_root = File.realpath(Dir.mktmpdir)
      session_path = nil
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "sessions/create", params: { workspaceRoot: workspace_root } },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })
      session_path = messages.find { |message| message["id"] == 1 }["result"]["path"]

      refute_path_exists session_path
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end
end
