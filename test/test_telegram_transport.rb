require "stringio"
require_relative "test_helper"
require_relative "../examples/plugins/telegram/telegram_transport"

class TestTelegramTransport < KwardTestCase
  def test_processes_an_authorized_message_once_and_replies_with_final_answer
    host = FakeTelegramHost.new
    api = FakeTelegramApi.new
    transport = build_transport(host, api)

    transport.send(:handle_update, message_update(text: "hello", update_id: 1))
    transport.send(:handle_update, message_update(text: "hello again", update_id: 1))

    assert_equal ["hello"], host.sessions.inputs
    assert_equal [{}], host.sessions.turn_options
    assert_equal ["answer"], api.sent_messages.map { |message| message[:text] }
    assert_equal 1, api.sent_messages.first[:reply_to_message_id]
    assert_equal 1, api.calls.count { |method, _| method == :send_message }
  end

  def test_delivers_assistant_message_event_content
    host = FakeTelegramHost.new
    api = FakeTelegramApi.new
    transport = build_transport(host, api)
    host.storage.put("telegram:turn:turn-1", {
      "chat_id" => 42,
      "reply_to_message_id" => 1
    })

    transport.send(:handle_turn_event, Kward::Transport.turn_event(
      type: "assistantMessage",
      session_id: "session-1",
      turn_id: "turn-1",
      sequence: 1,
      payload: { message: { "content" => "answer" } }
    ))

    assert_equal ["answer"], api.sent_messages.map { |message| message[:text] }
  end

  def test_rejects_messages_outside_both_allowlists
    host = FakeTelegramHost.new
    api = FakeTelegramApi.new
    transport = build_transport(host, api)

    transport.send(:handle_update, message_update(user_id: 99, chat_id: 42, update_id: 2))
    transport.send(:handle_update, message_update(user_id: 7, chat_id: 99, update_id: 3))

    assert_empty host.sessions.inputs
    assert_empty api.sent_messages
  end

  def test_splits_long_answers_for_telegram
    host = FakeTelegramHost.new(answer: "a" * 4097)
    api = FakeTelegramApi.new
    transport = build_transport(host, api)

    transport.send(:handle_update, message_update(update_id: 4))

    assert_equal [4096, 1], api.sent_messages.map { |message| message[:text].length }
  end

  def test_routes_tool_approval_callbacks_back_to_the_kward_session
    host = FakeTelegramHost.new
    api = FakeTelegramApi.new
    transport = build_transport(host, api, sleeper: ->(_seconds) { Thread.pass })
    transport.start
    wait_until { host.interaction_handler }
    transport.send(:handle_update, message_update(update_id: 5))

    request = Kward::Transport.interaction_request(
      id: "request-1",
      session_id: "session-1",
      turn_id: "turn-1",
      kind: "tool_approval",
      prompt: "Allow the tool?"
    )
    host.interaction_handler.call(request)
    callback_data = api.sent_messages.last[:reply_markup]["inline_keyboard"][0][0]["callback_data"]

    transport.send(:handle_update, {
      "update_id" => 6,
      "callback_query" => {
        "id" => "callback-1",
        "data" => callback_data,
        "from" => { "id" => 7 },
        "message" => { "chat" => { "id" => 42 } }
      }
    })

    assert_equal [["request-1", true]], host.sessions.answers
    assert_equal "callback-1", api.callback_answers.first[:callback_query_id]
  ensure
    transport&.stop
  end

  def test_start_validates_bot_and_stop_ends_polling_thread
    host = FakeTelegramHost.new
    api = FakeTelegramApi.new
    transport = build_transport(host, api, sleeper: ->(_seconds) { Thread.pass })

    transport.start
    wait_until { api.calls.any? { |method, _| method == :get_updates } }
    assert_equal "running", transport.health[:state]
    transport.stop

    assert_equal "stopped", transport.health[:state]
    assert_equal %i[delete_webhook get_me], api.calls.first(2).map(&:first)
  end

  private

  def build_transport(host, api, sleeper: ->(_seconds) {})
    Kward::Telegram::Transport.new(
      host: host,
      config: {
        "bot_token" => "test-token",
        "workspace" => "/tmp/fixed-workspace",
        "allowed_user_ids" => [7],
        "allowed_chat_ids" => [42],
        "poll_timeout_seconds" => 0
      },
      api: api,
      sleeper: sleeper
    )
  end

  def message_update(text: "hello", user_id: 7, chat_id: 42, update_id:)
    {
      "update_id" => update_id,
      "message" => {
        "message_id" => 1,
        "text" => text,
        "from" => { "id" => user_id, "username" => "captain" },
        "chat" => { "id" => chat_id }
      }
    }
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.001 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert yield, "condition was not met before timeout"
  end

  class FakeTelegramApi
    attr_reader :calls, :sent_messages, :callback_answers

    def initialize
      @calls = []
      @sent_messages = []
      @callback_answers = []
    end

    def delete_webhook(**options)
      @calls << [:delete_webhook, options]
      true
    end

    def get_me
      @calls << [:get_me, {}]
      { "id" => 1 }
    end

    def get_updates(**options)
      @calls << [:get_updates, options]
      []
    end

    def answer_callback_query(**message)
      @callback_answers << message
      true
    end

    def send_message(**message)
      @calls << [:send_message, message]
      @sent_messages << message
      { "message_id" => @sent_messages.length }
    end
  end

  class FakeTelegramHost
    attr_reader :storage, :sessions, :logger, :transport_id, :interaction_handler

    def initialize(answer: "answer")
      @storage = Kward::Transport::Store.new("com.kward.telegram", root: Dir.mktmpdir)
      @sessions = FakeTelegramSessions.new(answer: answer)
      @logger = Logger.new(StringIO.new)
      @transport_id = "com.kward.telegram"
      @interaction_handler = nil
    end

    def secret(name, env: nil)
      name == "bot_token" ? "test-token" : nil
    end

    def interactions
      self
    end

    def subscribe(&block)
      @interaction_handler = block
    end

    def authorize!(_action, **_attributes)
      true
    end
  end

  class FakeTelegramSessions
    attr_reader :inputs, :turn_options

    attr_reader :answers

    def initialize(answer:)
      @answer = answer
      @inputs = []
      @turn_options = []
      @answers = []
    end

    def resolve(**_attributes)
      FakeTelegramSession.new(@inputs, @turn_options, @answers, @answer)
    end
  end

  class FakeTelegramSession
    def initialize(inputs, turn_options, answers, answer)
      @inputs = inputs
      @turn_options = turn_options
      @answers = answers
      @answer = answer
    end

    def id
      "session-1"
    end

    def start_turn(input, **options)
      @inputs << input
      @turn_options << options
      FakeTelegramTurn.new(@answer)
    end

    def answer_interaction(request_id:, answer:)
      @answers << [request_id, answer]
    end
  end

  class FakeTelegramTurn
    def initialize(answer)
      @answer = answer
    end

    def id
      "turn-1"
    end

    def subscribe(&block)
      block.call(Kward::Transport.turn_event(
        type: "answer",
        session_id: "session-1",
        turn_id: "turn-1",
        sequence: 1,
        payload: { content: @answer }
      ))
    end
  end
end
