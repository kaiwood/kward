require_relative "test_helper"
require_relative "../examples/plugins/telegram_api"

class TestTelegramApi < KwardTestCase
  def test_get_updates_serializes_polling_parameters
    calls = []
    api = Kward::Telegram::BotApi.new(token: "123:secret", requester: lambda do |method, params|
      calls << [method, params]
      { "ok" => true, "result" => [{ "update_id" => 7 }] }
    end)

    assert_equal [{ "update_id" => 7 }], api.get_updates(offset: 7, timeout: 25)
    assert_equal "getUpdates", calls[0][0]
    assert_equal 7, calls[0][1]["offset"]
    assert_equal 25, calls[0][1]["timeout"]
    assert_equal %w[message callback_query], JSON.parse(calls[0][1]["allowed_updates"])
  end

  def test_answers_callback_queries
    calls = []
    api = Kward::Telegram::BotApi.new(token: "token", requester: lambda do |method, params|
      calls << [method, params]
      { "ok" => true, "result" => true }
    end)

    assert api.answer_callback_query(callback_query_id: "callback-1", text: "Done", show_alert: true)
    assert_equal ["answerCallbackQuery", { "callback_query_id" => "callback-1", "show_alert" => true, "text" => "Done" }], calls.first
  end

  def test_send_message_serializes_reply_parameters_and_buttons
    calls = []
    api = Kward::Telegram::BotApi.new(token: "123:secret", requester: lambda do |method, params|
      calls << [method, params]
      { "ok" => true, "result" => { "message_id" => 9 } }
    end)

    result = api.send_message(
      chat_id: 42,
      text: "Hello",
      reply_to_message_id: 8,
      reply_markup: { "inline_keyboard" => [[{ "text" => "Approve", "callback_data" => "approve" }]] }
    )

    assert_equal({ "message_id" => 9 }, result)
    assert_equal "sendMessage", calls[0][0]
    assert_equal 42, calls[0][1]["chat_id"]
    assert_equal({ "message_id" => 8 }, JSON.parse(calls[0][1]["reply_parameters"]))
    assert_equal "Approve", JSON.parse(calls[0][1]["reply_markup"])["inline_keyboard"][0][0]["text"]
  end

  def test_rate_limit_error_preserves_retry_after_without_exposing_token
    api = Kward::Telegram::BotApi.new(token: "123:secret", requester: lambda do |_method, _params|
      {
        "ok" => false,
        "error_code" => 429,
        "description" => "retry using https://api.telegram.org/bot123:secret",
        "parameters" => { "retry_after" => 4 }
      }
    end)

    error = assert_raises(Kward::Telegram::BotApi::RateLimitError) { api.get_me }

    assert_equal 4, error.retry_after
    refute_includes error.message, "123:secret"
  end

  def test_rejects_invalid_polling_timeout_and_missing_text
    api = Kward::Telegram::BotApi.new(token: "token", requester: ->(_method, _params) { { "ok" => true, "result" => nil } })

    assert_raises(ArgumentError) { api.get_updates(timeout: 51) }
    assert_raises(ArgumentError) { api.send_message(chat_id: 1, text: "") }
  end
end
