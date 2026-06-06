require_relative "test_support"

class TestRPCServer < KwardTestCase
  include KwardRPCTestSupport

  def test_initialize_and_shutdown
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "initialize" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ])

    assert_equal 1, messages[0]["result"]["protocolVersion"]
    capabilities = messages[0]["result"]["capabilities"]
    assert_equal "content-length", capabilities["framing"]

    detailed_groups = %w[transcript sessions turns events attachments models runtime runtimeSettings auth commands startupResources extensionUi security export logging]
    detailed_groups.each { |group| assert capabilities.key?(group), "missing capability group #{group}" }

    assert_equal "tauren-transcript-v1", capabilities["transcript"]["format"]
    assert_equal true, capabilities["transcript"]["messagesNormalized"]
    assert_equal true, capabilities["transcript"]["supportsCompactionSummaries"]
    assert_equal true, capabilities["transcript"]["supportsReasoningRestore"]
    assert_equal "explicit", capabilities["sessions"]["mode"]
    assert_equal "jsonl", capabilities["sessions"]["persistence"]
    assert_equal ["sessions/create", "sessions/resume", "sessions/list", "sessions/rename", "sessions/clone", "sessions/compact", "sessions/forkMessages", "sessions/fork", "sessions/export", "sessions/delete", "sessions/close", "sessions/transcript"], capabilities["sessions"]["methods"]
    assert_equal true, capabilities["sessions"]["list"]["supported"]
    assert_equal true, capabilities["sessions"]["fork"]["supported"]
    assert_equal ["sessions/forkMessages", "sessions/fork"], capabilities["sessions"]["fork"]["methods"]
    assert_equal true, capabilities["sessions"]["compact"]["supported"]
    assert_equal "sessions/compact", capabilities["sessions"]["compact"]["method"]
    assert_equal false, capabilities["sessions"]["import"]["supported"]
    assert_equal false, capabilities["sessions"]["tree"]["supported"]
    assert_equal false, capabilities["sessions"]["updates"]["supported"]
    assert_equal "async", capabilities["turns"]["mode"]
    assert_equal 1, capabilities["turns"]["perSessionConcurrency"]
    assert_equal "unsupported", capabilities["turns"]["busyInput"]["steer"]
    assert_equal "queue", capabilities["turns"]["busyInput"]["followUp"]
    assert_equal "newTurn", capabilities["turns"]["busyInput"]["defaultWhenIdle"]
    assert_equal "best-effort", capabilities["turns"]["cancellation"]["behavior"]
    assert_equal false, capabilities["turns"]["eventReplay"]["persisted"]
    assert_equal 1000, capabilities["turns"]["eventReplay"]["limit"]
    assert_equal "turn/event", capabilities["events"]["notification"]
    assert_equal true, capabilities["events"]["tools"]["normalizedMetadata"]
    assert_equal true, capabilities["events"]["tools"]["diffs"]
    assert_equal false, capabilities["events"]["tools"]["changedFiles"]
    assert_equal false, capabilities["events"]["sessionUpdates"]
    assert_equal true, capabilities["attachments"]["input"]["supported"]
    assert_equal ["image/png", "image/jpeg", "image/gif", "image/webp"], capabilities["attachments"]["input"]["mimeTypes"]
    assert_equal 10_485_760, capabilities["attachments"]["input"]["maxBytes"]
    assert_includes capabilities["models"]["methods"], "models/set"
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
    assert_equal ["openai"], capabilities["auth"]["oauthProviders"]
    assert_equal ["openrouter"], capabilities["auth"]["apiKeyProviders"]
    assert_equal true, capabilities["auth"]["logout"]
    assert_includes capabilities["auth"]["methods"], "auth/providers"
    assert_includes capabilities["auth"]["methods"], "auth/loginWithApiKey"
    assert_includes capabilities["auth"]["methods"], "auth/logoutProvider"
    assert_includes capabilities["auth"]["methods"], "auth/loginWithOAuth"
    assert_equal true, capabilities["commands"]["supported"]
    assert_equal ["prompt", "skill", "plugin"], capabilities["commands"]["sources"]
    assert_equal ["plugin"], capabilities["commands"]["executableSources"]
    assert_equal "commands/run", capabilities["commands"]["runMethod"]
    assert_equal true, capabilities["startupResources"]["supported"]
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
      "footer" => false,
      "custom" => false,
      "terminalInput" => false
    }, capabilities["extensionUi"])
    assert_equal "none", capabilities["security"]["workspaceMutationGuard"]
    assert_equal "none", capabilities["security"]["toolApproval"]
    assert_equal ["markdown", "html"], capabilities["export"]["formats"]
    assert_equal true, capabilities["logging"]["supported"]
    assert_equal false, capabilities["logging"]["defaultEnabled"]
    assert_equal ["logging/stats"], capabilities["logging"]["methods"]
    assert_equal "1 week", capabilities["logging"]["stats"]["defaultRange"]
    assert_equal ["tokens", "performance", "tools", "errors"], capabilities["logging"]["categories"]
    assert_equal 10_485_760, capabilities["logging"]["rotation"]["maxBytes"]
    assert_equal "redacted-metadata-only", capabilities["logging"]["content"]

    assert_equal true, capabilities["asyncTurns"]
    assert_equal "explicit", capabilities["session"]["mode"]
    assert_equal true, capabilities["config"]["supported"]
    assert_equal true, messages[1]["result"]["ok"]
  end

  def test_initialize_capability_method_lists_match_rpc_methods
    messages = run_rpc([
      { jsonrpc: "2.0", id: 1, method: "initialize" },
      { jsonrpc: "2.0", id: 2, method: "shutdown" }
    ])
    capabilities = messages[0]["result"]["capabilities"]

    assert_equal ["models/list", "models/current", "models/set", "reasoning/set"], capabilities["models"]["methods"]
    assert_equal ["runtime/state", "runtime/stats"], capabilities["runtime"]["methods"]
    assert_equal ["runtime/updateSetting", "runtime/reload"], capabilities["runtimeSettings"]["methods"]
    assert_equal ["auth/status", "auth/providers", "auth/loginWithApiKey", "auth/logoutProvider", "auth/loginWithOAuth", "auth/startOpenAILogin", "auth/submitOpenAICode", "auth/loginStatus"], capabilities["auth"]["methods"]
    assert_equal ["prompts/list", "prompts/expand"], capabilities["prompts"]["methods"]
    assert_equal ["config/read", "config/update"], capabilities["config"]["methods"]
    assert_equal ["logging/stats"], capabilities["logging"]["methods"]
    assert_equal "tools/list", capabilities["tools"]["method"]
    assert_equal "commands/list", capabilities["commands"]["method"]
    assert_includes capabilities["commands"]["methods"], "commands/run"
    assert_equal "resources/startup", capabilities["startupResources"]["method"]
    assert_includes capabilities["sessions"]["methods"], "sessions/compact"
    assert_includes capabilities["sessions"]["methods"], "sessions/delete"
    assert_includes capabilities["sessions"]["methods"], "sessions/close"
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

  def test_turn_start_rpc_invalid_params_for_attachments_and_streaming_behavior
    output = StringIO.new
    server = Kward::RPC::Server.new(input: StringIO.new, output: output, error_output: StringIO.new, client: FakeClient.new([]))
    session = server.instance_variable_get(:@session_manager).create_session(workspace_root: Dir.pwd)

    server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 1, "method" => "turns/start", "params" => { "sessionId" => session[:id], "input" => "bad", "attachments" => [{ "type" => "image", "data" => "YQ==", "mimeType" => "image/svg+xml" }] } })
    server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 2, "method" => "turns/start", "params" => { "sessionId" => session[:id], "input" => "large", "attachments" => [{ "type" => "image", "data" => "YQ==", "mimeType" => "image/png", "sizeBytes" => Kward::RPC::SessionManager::RPC_ATTACHMENT_MAX_BYTES + 1 }] } })
    server.send(:handle_message, { "jsonrpc" => "2.0", "id" => 3, "method" => "turns/start", "params" => { "sessionId" => session[:id], "input" => "steer", "streamingBehavior" => "steer" } })

    messages = read_framed_messages(output)
    assert_equal [-32_602, -32_602, -32_602], messages.map { |message| message["error"]["code"] }
    assert_equal "Unsupported image MIME type: image/svg+xml", messages[0]["error"]["message"]
    assert_equal "Image attachment is too large", messages[1]["error"]["message"]
    assert_equal "Unsupported streamingBehavior: steer", messages[2]["error"]["message"]
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

  def test_rpc_shutdown_deletes_empty_unnamed_sessions
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      workspace_root = File.realpath(Dir.mktmpdir)
      session_path = nil
      messages = run_rpc([
        { jsonrpc: "2.0", id: 1, method: "sessions/create", params: { workspaceRoot: workspace_root } },
        { jsonrpc: "2.0", id: 2, method: "shutdown" }
      ], env: { "KWARD_CONFIG_PATH" => config_path })
      session_path = messages[0]["result"]["path"]

      refute_path_exists session_path
    ensure
      FileUtils.remove_entry(workspace_root) if workspace_root && File.exist?(workspace_root)
    end
  end
end
