require_relative "test_support"

class TestRPCSessionManagerRuntime < KwardTestCase
  include KwardRPCTestSupport

  def test_current_model_does_not_give_fake_model_a_production_context_window
    client = FakeClient.new([])
    client.context_window = nil
    manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client)

    model = manager.current_model

    assert_equal "fake-model", model[:id]
    refute model.key?(:contextWindow)
  end

  def test_runtime_state_returns_session_and_model_info
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({}))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
        session = manager.create_session(workspace_root: Dir.pwd, name: "Work")
        rpc_session = manager.send(:fetch_session, session[:id])
        rpc_session.conversation.append_user("hello")

        state = manager.runtime_state(session_id: session[:id])

        assert_equal session[:path], state[:sessionFile]
        assert_equal session[:persistentId], state[:sessionId]
        assert_equal session[:id], state[:rpcSessionId]
        assert_equal session[:persistentId], state[:persistentSessionId]
        assert_equal "Work", state[:sessionName]
        assert_equal "kward-rpc", state[:transport]
        assert_equal false, state[:isStreaming]
        assert_equal 1, state[:messageCount]
        assert_equal 0, state[:pendingMessageCount]
        assert_equal "Codex", state[:model][:provider]
        assert_equal "fake-model", state[:model][:id]
        assert_equal "fake-model", state[:model][:name]
        assert_equal true, state[:model][:reasoning]
        assert_equal 20_000, state[:autoCompactionReserveTokens]
        assert_equal "medium", state[:thinkingLevel]
        assert_equal "Codex/fake-model", state[:defaultModel]
        assert_equal "Assistant", state[:activePersonaLabel]
      end
    end
  end

  def test_runtime_state_returns_active_persona_label
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({
        "personas" => {
          "characters" => [
            { "key" => "kward", "label" => "Kward", "instruction" => "Default persona." }
          ],
          "default" => "kward"
        }
      }))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
        session = manager.create_session(workspace_root: Dir.pwd)

        state = manager.runtime_state(session_id: session[:id])

        assert_equal "Kward", state[:activePersonaLabel]
      end
    end
  end

  def test_runtime_state_returns_model_specific_active_persona_label
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({
        "personas" => {
          "characters" => [
            { "key" => "kward", "label" => "Kward", "instruction" => "Default persona." },
            { "key" => "sam", "label" => "Samantha", "instruction" => "Model persona." }
          ],
          "default" => "kward",
          "models" => { "fake-model" => "sam" }
        }
      }))

      with_env("KWARD_CONFIG_PATH" => config_path) do
        manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
        session = manager.create_session(workspace_root: Dir.pwd)

        state = manager.runtime_state(session_id: session[:id])

        assert_equal "Samantha", state[:activePersonaLabel]
      end
    end
  end

  def test_runtime_state_reports_reasoning_for_copilot_gpt_5_responses_models
    Dir.mktmpdir do |config_dir|
      client = FakeClient.new([])
      client.provider = "Copilot"
      client.model = "gpt-5-mini"
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd, name: "Work")

      state = manager.runtime_state(session_id: session[:id])

      assert_equal "Copilot", state[:model][:provider]
      assert_equal "gpt-5-mini", state[:model][:id]
      assert_equal true, state[:model][:reasoning]
      assert_equal "medium", state[:model][:reasoningEffort]
      assert_equal "medium", state[:thinkingLevel]
    end
  end

  def test_runtime_state_keeps_reasoning_unavailable_for_copilot_chat_models
    Dir.mktmpdir do |config_dir|
      client = FakeClient.new([])
      client.provider = "Copilot"
      client.model = "gemini-2.5-pro"
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd, name: "Work")

      state = manager.runtime_state(session_id: session[:id])

      assert_equal "Copilot", state[:model][:provider]
      assert_equal "gemini-2.5-pro", state[:model][:id]
      assert_equal false, state[:model][:reasoning]
      refute state[:model].key?(:reasoningEffort)
    end
  end

  def test_refresh_client_config_rebuilds_active_session_tool_registry
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      File.write(config_path, JSON.dump({ "web_search" => { "enabled" => false } }))
      client = ToolRecordingClient.new

      with_env("KWARD_CONFIG_PATH" => config_path) do
        manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
        session = manager.create_session(workspace_root: Dir.pwd)

        turn = manager.start_turn(session_id: session[:id], input: "before")
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }
        refute_includes client.seen_tools.first.map { |tool| tool[:function][:name] }, "web_search"

        File.write(config_path, JSON.dump({ "web_search" => { "enabled" => true } }))
        manager.refresh_client_config
        turn = manager.start_turn(session_id: session[:id], input: "after")
        wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

        assert_includes client.seen_tools.last.map { |tool| tool[:function][:name] }, "web_search"
      end
    end
  end

  def test_runtime_stats_counts_messages_and_tool_activity
    Dir.mktmpdir do |config_dir|
      context_usage = StaticContextUsage.new(tokens: 50)
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir, context_usage: context_usage)
      session = manager.create_session(workspace_root: Dir.pwd, name: "Stats")
      rpc_session = manager.send(:fetch_session, session[:id])

      rpc_session.conversation.append_user("hello")
      rpc_session.conversation.append_assistant(assistant_tool_call("read_file", { path: "README.md" }))
      rpc_session.conversation.append_tool(tool_call_id: "call_read_file", name: "read_file", content: "contents")
      rpc_session.conversation.append_assistant("done")

      stats = manager.runtime_stats(session_id: session[:id])

      assert_equal session[:path], stats[:sessionFile]
      assert_equal session[:persistentId], stats[:sessionId]
      assert_equal session[:id], stats[:rpcSessionId]
      assert_equal session[:persistentId], stats[:persistentSessionId]
      assert_equal "Stats", stats[:sessionName]
      assert_equal 1, stats[:userMessages]
      assert_equal 2, stats[:assistantMessages]
      assert_equal 1, stats[:toolCalls]
      assert_equal 1, stats[:toolResults]
      assert_equal 4, stats[:totalMessages]
      assert_equal true, stats[:usingSubscription]
      assert_equal true, stats[:autoCompactionEnabled]
      assert_equal 20_000, stats[:autoCompactionReserveTokens]
      assert_equal({ tokens: 50, contextWindow: 200_000, percent: 0.03 }, stats[:contextUsage])
      refute stats.key?(:tokens)
    end
  end
end
