require_relative "test_support"

class TestRPCSessionManagerTurns < KwardTestCase
  include KwardRPCTestSupport

  def test_session_manager_turn_events_complete_and_replay
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: MarkdownStreamingClient.new(["reply"]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: session[:id], input: "hello")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      events = manager.turn_events(turn_id: turn[:id], after_sequence: 0)[:events]
      assert events.any? { |event| event[:type] == "assistantDelta" && event[:payload][:delta] == "reply" }
      assert events.any? { |event| event[:type] == "answer" && event[:payload][:content] == "reply" }
      assert_equal "completed", manager.turn_status(turn_id: turn[:id])[:status]
      assert server.notifications.any? { |notification| notification[:method] == "turn/event" }
    end
  end

  def test_turn_events_have_stable_lifecycle_reasoning_and_replay_filter
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: ReasoningStreamingClient.new, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: session[:id], input: "think")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      events = manager.turn_events(turn_id: turn[:id], after_sequence: 0)[:events]
      assert_equal "turnQueued", events[0][:type]
      assert_equal "turnStarted", events[1][:type]
      assert_equal "turnFinished", events[-1][:type]
      assert_equal 1, events.count { |event| event[:type] == "turnFinished" }
      assert_equal "completed", events[-1][:payload][:status]
      assert events.each_cons(2).all? { |left, right| left[:sequence] < right[:sequence] }

      reasoning = events.find { |event| event[:type] == "reasoningDelta" }
      assert_equal({ delta: "because" }, reasoning[:payload])
      assistant = events.find { |event| event[:type] == "assistantDelta" }
      assert_equal({ delta: "answer" }, assistant[:payload])

      replayed = manager.turn_events(turn_id: turn[:id], after_sequence: reasoning[:sequence])[:events]
      refute_includes replayed.map { |event| event[:type] }, "reasoningDelta"
      assert_includes replayed.map { |event| event[:type] }, "assistantDelta"
    end
  end

  def test_retry_event_is_emitted_and_replayed
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: RetryEventClient.new, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: session[:id], input: "retry")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      retry_event = manager.turn_events(turn_id: turn[:id], after_sequence: 0)[:events].find { |event| event[:type] == "modelRetry" }
      assert_equal "Codex", retry_event[:payload][:provider]
      assert_equal "fake-model", retry_event[:payload][:model]
      assert_equal 2, retry_event[:payload][:attempt]
      assert_equal 3, retry_event[:payload][:maxAttempts]
      assert_equal 1, retry_event[:payload][:delaySeconds]
      assert_equal "Codex request failed: 503 upstream", retry_event[:payload][:error]
      assert server.notifications.any? { |notification| notification[:params][:type] == "modelRetry" }
    end
  end

  def test_session_manager_queues_turns_per_session
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      client = RecordingClient.new(["one", "two"])
      manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      first = manager.start_turn(session_id: session[:id], input: "first")
      second = manager.start_turn(session_id: session[:id], input: "second", streaming_behavior: "followUp")

      wait_until { manager.turn_status(turn_id: second[:id])[:status] == "completed" }

      assert_equal "first", client.seen_messages[0][1][:content]
      assert_equal "second", client.seen_messages[1][3][:content]
      assert_equal "completed", manager.turn_status(turn_id: first[:id])[:status]
      assert_equal "completed", manager.turn_status(turn_id: second[:id])[:status]
    end
  end

  def test_session_manager_steers_running_turn_when_provider_supports_it
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      client = SteeringClient.new
      manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: session[:id], input: "first")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "running" }
      steered = manager.start_turn(session_id: session[:id], input: "steer me")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      assert_equal turn[:id], steered[:id]
      assert_equal ["steer me"], client.steered_inputs
      assert_equal "completed", manager.turn_status(turn_id: turn[:id])[:status]
      events = manager.turn_events(turn_id: turn[:id])[:events]
      assert_equal 1, events.count { |event| event[:type] == "turnQueued" }
      assert events.any? { |event| event[:type] == "turnSteered" && event[:payload][:input] == "steer me" }
      assert events.any? { |event| event[:type] == "assistantDelta" && event[:payload][:delta] == "before" }
      assert events.any? { |event| event[:type] == "assistantDelta" && event[:payload][:delta] == "after" }
    end
  end

  def test_turn_start_accepts_image_attachment_and_restores_transcript
    Dir.mktmpdir do |config_dir|
      png_data = "iVBORw0KGgo="
      client = RecordingClient.new(["ok"])
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(
        session_id: session[:id],
        input: "describe this",
        attachments: [{ type: "image", data: png_data, mimeType: "image/png", name: "pixel.png", sizeBytes: 8 }]
      )

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

      content = client.seen_messages[0][1][:content]
      assert_equal({ type: "text", text: "describe this" }, content[0])
      assert_equal({ type: "image", data: png_data, mimeType: "image/png", alt: "pixel.png" }, content[1])

      user_message = manager.transcript(session_id: session[:id])[:messages].find { |message| message[:role] == "user" }
      assert_equal "describe this", user_message[:content][0][:text]
      image = user_message[:content][1]
      assert_equal "image", image[:type]
      assert_equal png_data, image[:data]
      assert_equal "image/png", image[:mimeType]
      assert_equal "pixel.png", image[:alt]
    end
  end

  def test_turn_start_rejects_invalid_attachments_and_unsupported_streaming_behavior
    Dir.mktmpdir do |config_dir|
      manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: FakeClient.new([]), config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)

      assert_raises(ArgumentError) do
        manager.start_turn(session_id: session[:id], input: "bad", attachments: [{ type: "image", data: "YQ==", mimeType: "image/svg+xml" }])
      end

      error = assert_raises(ArgumentError) do
        manager.start_turn(session_id: session[:id], input: "large", attachments: [{ type: "image", data: "YQ==", mimeType: "image/png", sizeBytes: Kward::RPC::SessionManager::RPC_ATTACHMENT_MAX_BYTES + 1 }])
      end
      assert_equal "Image attachment is too large", error.message

      large_data = Base64.strict_encode64("a" * (Kward::RPC::SessionManager::RPC_ATTACHMENT_MAX_BYTES + 1))
      error = assert_raises(ArgumentError) do
        manager.start_turn(session_id: session[:id], input: "large", attachments: [{ type: "image", data: large_data, mimeType: "image/png" }])
      end
      assert_equal "Image attachment is too large", error.message

      error = assert_raises(ArgumentError) do
        manager.start_turn(session_id: session[:id], input: "steer", streaming_behavior: "steer")
      end
      assert_equal "Unsupported streamingBehavior: steer", error.message
    end
  end

  def test_cancel_queued_turn_is_best_effort
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      manager = Kward::RPC::SessionManager.new(server: server, client: SlowClient.new, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      first = manager.start_turn(session_id: session[:id], input: "first")
      second = manager.start_turn(session_id: session[:id], input: "second")

      manager.cancel_turn(turn_id: second[:id])

      assert_equal "canceled", manager.turn_status(turn_id: second[:id])[:status]
      assert_equal true, manager.turn_status(turn_id: second[:id])[:cancelRequested]
      second_events = manager.turn_events(turn_id: second[:id])[:events]
      assert_equal "canceled", second_events.find { |event| event[:type] == "turnFinished" }[:payload][:status]
      wait_until { manager.turn_status(turn_id: first[:id])[:status] == "completed" }
    end
  end

  def test_cancel_running_turn_signals_client_and_finishes_promptly
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      client = BlockingCancellableClient.new
      manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      turn = manager.start_turn(session_id: session[:id], input: "running")

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "running" }
      manager.cancel_turn(turn_id: turn[:id])

      wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "canceled" }
      assert_equal true, client.cancelled?
      assert_equal true, manager.turn_status(turn_id: turn[:id])[:cancelRequested]
      events = manager.turn_events(turn_id: turn[:id])[:events]
      assert_equal "turnCancelRequested", events[-2][:type]
      assert_equal "turnFinished", events[-1][:type]
      assert_equal "canceled", events[-1][:payload][:status]
      refute events.any? { |event| event[:type] == "assistantMessage" }
    end
  end

  def test_cancel_turn_waiting_for_rpc_question_unblocks_worker
    Dir.mktmpdir do |config_dir|
      server = RecordingServer.new
      client = FakeClient.new([
        assistant_tool_call("ask_user_question", { questions: [question_args("Continue?")] }),
        { "role" => "assistant", "content" => "after cancel" }
      ])
      manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
      session = manager.create_session(workspace_root: Dir.pwd)
      blocked = manager.start_turn(session_id: session[:id], input: "ask")

      wait_until { server.notifications.any? { |notification| notification[:method] == "ui/question" } }
      manager.cancel_turn(turn_id: blocked[:id])

      wait_until { manager.turn_status(turn_id: blocked[:id])[:status] == "canceled" }
      follow_up = manager.start_turn(session_id: session[:id], input: "next")
      wait_until { manager.turn_status(turn_id: follow_up[:id])[:status] == "completed" }

      assert_equal true, manager.turn_status(turn_id: blocked[:id])[:cancelRequested]
      assert_equal "after cancel", manager.turn_events(turn_id: follow_up[:id])[:events].find { |event| event[:type] == "answer" }[:payload][:content]
    end
  end

  def test_rpc_turn_expands_configured_prompt_slash_commands
    Dir.mktmpdir do |config_dir|
      config_path = File.join(config_dir, "config.json")
      prompts_dir = File.join(config_dir, "prompts")
      FileUtils.mkdir_p(prompts_dir)
      File.write(File.join(config_dir, "config.json"), JSON.dump({}))
      File.write(File.join(prompts_dir, "plan.md"), "Plan this:\n$ARGUMENTS\n")
      client = RecordingClient.new(["planned", "literal"])

      with_env("KWARD_CONFIG_PATH" => config_path) do
        manager = Kward::RPC::SessionManager.new(server: RecordingServer.new, client: client, config_dir: config_dir)
        session = manager.create_session(workspace_root: Dir.pwd)
        plan_turn = manager.start_turn(session_id: session[:id], input: "/plan fix bug")
        wait_until { manager.turn_status(turn_id: plan_turn[:id])[:status] == "completed" }

        unknown_turn = manager.start_turn(session_id: session[:id], input: "/unknown fix bug")
        wait_until { manager.turn_status(turn_id: unknown_turn[:id])[:status] == "completed" }
      end

      assert_equal "Plan this:\nfix bug\n", client.seen_messages[0][1][:content]
      assert_equal "/unknown fix bug", client.seen_messages[1].last[:content]
    end
  end

  def test_rpc_turn_runs_plugin_slash_command_without_calling_client
    Dir.mktmpdir do |config_dir|
      Dir.mktmpdir do |home|
        config_path = File.join(config_dir, "config.json")
        plugins_dir = File.join(home, ".kward", "plugins")
        FileUtils.mkdir_p(plugins_dir)
        File.write(config_path, JSON.dump({}))
        File.write(File.join(plugins_dir, "hi_chatgpt.rb"), <<~'RUBY')
          Kward.plugin do |plugin|
            plugin.command "hi_chatgpt", description: "Say hi" do |args, ctx|
              ctx.say("Hi #{args}; messages=#{ctx.transcript.messages.length}")
              "returned #{args}"
            end
          end
        RUBY
        server = RecordingServer.new
        client = RecordingClient.new([])

        with_env("HOME" => home, "KWARD_CONFIG_PATH" => config_path) do
          manager = Kward::RPC::SessionManager.new(server: server, client: client, config_dir: config_dir)
          session = manager.create_session(workspace_root: Dir.pwd)
          turn = manager.start_turn(session_id: session[:id], input: "/hi_chatgpt Martok")
          wait_until { manager.turn_status(turn_id: turn[:id])[:status] == "completed" }

          events = manager.turn_events(turn_id: turn[:id], after_sequence: 0)[:events]
          assert_equal "Hi Martok; messages=1\nreturned Martok", events.find { |event| event[:type] == "answer" }[:payload][:content]
          assert events.any? { |event| event[:type] == "assistantDelta" && event[:payload][:delta].include?("Hi Martok") }
        end

        assert_empty client.seen_messages
      end
    end
  end
end
