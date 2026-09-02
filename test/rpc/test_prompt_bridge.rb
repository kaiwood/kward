require_relative "test_support"

class TestRPCPromptBridge < KwardTestCase
  include KwardRPCTestSupport

  def test_prompt_bridge_normalizes_rpc_answer_string_keys_for_tool_prompt
    server = RecordingServer.new
    bridge = Kward::RPC::PromptBridge.new(server: server, session_id: "session-1")
    answer_thread = Thread.new do
      wait_until { server.notifications.any? }
      params = server.notifications.first[:params]
      bridge.answer(params[:questionRequestId], [{ "question" => "Continue?", "answer" => "Yes" }])
    end

    answers = bridge.ask_user_question([question_args("Continue?")])

    assert_equal [{ question: "Continue?", answer: "Yes" }], answers
  ensure
    answer_thread&.join
  end

  def test_prompt_bridge_brokers_questions_to_rpc_ui
    server = RecordingServer.new
    bridge = Kward::RPC::PromptBridge.new(server: server, session_id: "session-1")
    answer_thread = Thread.new do
      wait_until { server.notifications.any? }
      params = server.notifications.first[:params]
      bridge.answer(params[:questionRequestId], [{ question: "Continue?", answer: "Yes" }])
    end

    answers = bridge.ask_user_question([question_args("Continue?")])

    assert_equal [{ question: "Continue?", answer: "Yes" }], answers
    assert_equal "ui/question", server.notifications.first[:method]
  ensure
    answer_thread&.join
  end

  def test_prompt_bridge_brokers_plugin_ui_requests
    server = RecordingServer.new
    bridge = Kward::RPC::PromptBridge.new(server: server, session_id: "session-1")
    answer_thread = Thread.new do
      wait_until { server.notifications.any? }
      params = server.notifications.first[:params]
      bridge.answer_plugin_ui(params[:requestId], "deploy")
    end

    answer = bridge.request_plugin_ui(:select, { title: "Action", options: [{ label: "Deploy", value: "deploy" }] })

    assert_equal "deploy", answer
    assert_equal "ui/request", server.notifications.first[:method]
    assert_equal "select", server.notifications.first[:params][:kind]
    assert_equal "session-1", server.notifications.first[:params][:sessionId]
  ensure
    answer_thread&.join
  end

  def test_plugin_ui_request_is_released_by_cancellation
    server = RecordingServer.new
    bridge = Kward::RPC::PromptBridge.new(server: server, session_id: "session-1")
    cancellation = Kward::Cancellation.new
    answer = :pending
    thread = Thread.new do
      answer = bridge.request_plugin_ui(:input, { title: "Name" }, cancellation: cancellation)
    end
    wait_until { server.notifications.any? }

    cancellation.cancel!
    thread.join(1)

    assert_nil answer
    refute thread.alive?
  ensure
    thread&.kill if thread&.alive?
  end

  def test_prompt_bridge_validates_question_contract
    server = RecordingServer.new
    bridge = Kward::RPC::PromptBridge.new(server: server, session_id: "session-1")

    error = assert_raises(ArgumentError) { bridge.ask_user_question([]) }
    assert_equal "ui/question requires 1-4 questions", error.message

    too_many = Array.new(5) { question_args("Continue?") }
    error = assert_raises(ArgumentError) { bridge.ask_user_question(too_many) }
    assert_equal "ui/question requires 1-4 questions", error.message

    error = assert_raises(ArgumentError) do
      bridge.ask_user_question([{ question: "Continue?", header: "Confirm", options: [{ label: "Yes", description: "Continue." }] }])
    end
    assert_equal "question 1 requires 2-4 options", error.message

    error = assert_raises(ArgumentError) do
      bridge.ask_user_question([{ question: "Continue?", header: "Confirm", multiSelect: true, options: question_args("Continue?")[:options] }])
    end
    assert_equal "question 1 multiSelect is unsupported", error.message

    error = assert_raises(ArgumentError) do
      bridge.ask_user_question([{ question: "Continue?", header: "Confirm", options: [{ label: "Yes", description: "Continue.", preview: "code" }, { label: "No", description: "Stop." }] }])
    end
    assert_equal "question 1 preview is unsupported", error.message

    error = assert_raises(ArgumentError) do
      bridge.ask_user_question([{ question: "", header: "Confirm", options: question_args("Continue?")[:options] }])
    end
    assert_equal "question 1 requires question and header", error.message

    error = assert_raises(ArgumentError) do
      bridge.ask_user_question([{ question: "Continue?", header: "Confirm", options: [{ label: "", description: "Continue." }, { label: "No", description: "Stop." }] }])
    end
    assert_equal "question 1 option 1 requires label and description", error.message
    assert_empty server.notifications
  end
end
