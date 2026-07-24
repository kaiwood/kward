require "thread"
require_relative "telegram_api"

module Kward
  module Telegram
    # Long-polling Telegram adapter backed by normal Kward sessions.
    class Transport
      TELEGRAM_MESSAGE_LIMIT = 4096
      DEFAULT_POLL_TIMEOUT = 25
      MAX_RETRY_DELAY = 30

      def initialize(host:, config:, api: nil, sleeper: nil)
        @host = host
        @config = config || {}
        @token = host.secret("bot_token", env: "TELEGRAM_BOT_TOKEN")
        @workspace = required_config("workspace")
        @allowed_user_ids = required_ids("allowed_user_ids")
        @allowed_chat_ids = required_ids("allowed_chat_ids")
        @poll_timeout = Integer(@config.fetch("poll_timeout_seconds", DEFAULT_POLL_TIMEOUT))
        raise ArgumentError, "poll_timeout_seconds must be between 0 and 50" unless (0..50).cover?(@poll_timeout)

        @api = api || BotApi.new(token: @token)
        @sleeper = sleeper || method(:sleep)
        @state_mutex = Mutex.new
        @stop = false
        @thread = nil
        @last_error = nil
      end

      def start
        @api.delete_webhook
        @api.get_me
        @host.interactions.subscribe { |request| handle_interaction(request) }
        @state_mutex.synchronize do
          @stop = false
          @last_error = nil
          @thread = Thread.new { poll_loop }
        end
        nil
      end

      def stop
        thread = @state_mutex.synchronize do
          @stop = true
          @thread
        end
        return nil unless thread

        thread.join(@poll_timeout + 10)
        thread.kill if thread.alive?
        @state_mutex.synchronize { @thread = nil }
        nil
      end

      def health
        @state_mutex.synchronize do
          {
            state: @thread&.alive? ? "running" : "stopped",
            error: @last_error
          }
        end
      end

      private

      def poll_loop
        offset = Integer(@host.storage.get("telegram:offset") || 0)
        until stopping?
          begin
            updates = @api.get_updates(offset: offset, timeout: @poll_timeout)
            updates.each do |update|
              update_id = Integer(update.fetch("update_id"))
              handle_update(update)
              offset = [offset, update_id + 1].max
              @host.storage.put("telegram:offset", offset)
            end
          rescue BotApi::RateLimitError => error
            record_error(error)
            wait_for([error.retry_after, MAX_RETRY_DELAY].min)
          rescue StandardError => error
            record_error(error)
            wait_for(2)
          end
        end
      end

      def handle_update(update)
        if update["callback_query"]
          handle_callback(update.fetch("callback_query"))
        elsif update["message"]
          handle_message(update.fetch("message"), update.fetch("update_id"))
        end
      rescue StandardError => error
        record_error(error)
      end

      def handle_message(message, update_id)
        text = message["text"].to_s
        return if text.empty?

        user_id = Integer(message.fetch("from").fetch("id"))
        chat_id = Integer(message.fetch("chat").fetch("id"))
        return unless allowed?(user_id, chat_id)
        return unless @host.storage.claim("telegram:update:#{update_id}")

        conversation = Kward::Transport.conversation_key(
          transport_id: @host.transport_id,
          external_id: "chat:#{chat_id}"
        )
        actor = Kward::Transport.actor(
          id: "telegram:user:#{user_id}",
          display_name: message.dig("from", "username") || user_id.to_s,
          metadata: { provider: "telegram", user_id: user_id, chat_id: chat_id }
        )
        @host.authorize!(:telegram_message, actor: actor, conversation: conversation)

        session = @host.sessions.resolve(
          conversation: conversation,
          actor: actor,
          workspace_root: @workspace,
          name: "Telegram chat #{chat_id}"
        )
        remember_session(session, conversation, chat_id, actor)

        turn = session.start_turn(text)
        @host.storage.put("telegram:turn:#{turn.id}", {
          "chat_id" => chat_id,
          "session_id" => session.id,
          "reply_to_message_id" => message["message_id"]
        })
        turn.subscribe { |event| handle_turn_event(event) }
      end

      def handle_turn_event(event)
        return unless %w[answer assistantMessage].include?(event.type)

        turn = @host.storage.get("telegram:turn:#{event.turn_id}")
        return unless turn
        return if @host.storage.get("telegram:delivered:#{event.turn_id}")

        content = event.payload[:content] || event.payload["content"]
        return if content.to_s.empty?

        split_message(content.to_s).each do |part|
          @api.send_message(
            chat_id: turn.fetch("chat_id"),
            text: part,
            reply_to_message_id: turn["reply_to_message_id"]
          )
        end
        @host.storage.put("telegram:delivered:#{event.turn_id}", true)
      rescue StandardError => error
        record_error(error)
      end

      def handle_interaction(request)
        session = @host.storage.get("telegram:session:#{request.session_id}")
        return unless session

        record = {
          "chat_id" => session.fetch("chat_id"),
          "session_id" => request.session_id,
          "external_id" => session.fetch("external_id"),
          "actor_id" => session.fetch("actor_id"),
          "actor_name" => session["actor_name"],
          "kind" => request.kind.to_s
        }
        buttons = case request.kind.to_s
                  when "tool_approval"
                    record["answers"] = { "approve" => true, "deny" => false }
                    [[
                      { "text" => "Approve", "callback_data" => callback_data(request.id, "approve") },
                      { "text" => "Deny", "callback_data" => callback_data(request.id, "deny") }
                    ]]
                  when "question"
                    question, options = question_options(request)
                    return if options.empty?

                    record["question"] = question
                    record["answers"] = options.each_with_index.to_h { |option, index| [index.to_s, option] }
                    [options.each_with_index.map do |option, index|
                      { "text" => option, "callback_data" => callback_data(request.id, index.to_s) }
                    end]
                  else
                    return
                  end

        @host.storage.put("telegram:interaction:#{request.id}", record)
        @api.send_message(
          chat_id: record.fetch("chat_id"),
          text: request.prompt,
          reply_markup: { "inline_keyboard" => buttons }
        )
      rescue StandardError => error
        record_error(error)
      end

      def handle_callback(callback)
        data = callback["data"].to_s
        match = /\Akward:([^:]+):([^:]+)\z/.match(data)
        return unless match

        request_id, choice = match.captures
        chat_id = Integer(callback.fetch("message").fetch("chat").fetch("id"))
        user_id = Integer(callback.fetch("from").fetch("id"))
        return unless allowed?(user_id, chat_id)

        record = @host.storage.get("telegram:interaction:#{request_id}")
        return unless record && record.fetch("chat_id") == chat_id
        return unless record.fetch("actor_id") == "telegram:user:#{user_id}"
        return if @host.storage.get("telegram:answered:#{request_id}")

        conversation = Kward::Transport.conversation_key(
          transport_id: @host.transport_id,
          external_id: record.fetch("external_id")
        )
        actor = Kward::Transport.actor(
          id: record.fetch("actor_id"),
          display_name: record["actor_name"],
          metadata: { provider: "telegram", user_id: user_id, chat_id: chat_id }
        )
        session = @host.sessions.resolve(
          conversation: conversation,
          actor: actor,
          workspace_root: @workspace
        )
        answer = record.fetch("answers").fetch(choice)
        answer = [{ question: record.fetch("question"), answer: answer }] if record.fetch("kind") == "question"
        session.answer_interaction(request_id: request_id, answer: answer)
        @host.storage.put("telegram:answered:#{request_id}", true)
        @api.answer_callback_query(callback_query_id: callback.fetch("id"))
      rescue StandardError => error
        record_error(error)
      end

      def remember_session(session, conversation, chat_id, actor)
        @host.storage.put("telegram:session:#{session.id}", {
          "chat_id" => chat_id,
          "external_id" => conversation.external_id,
          "actor_id" => actor.id,
          "actor_name" => actor.display_name
        })
      end

      def question_options(request)
        question = request.choices.first || {}
        options = Array(question[:options] || question["options"]).map do |option|
          (option[:label] || option["label"]).to_s
        end.reject(&:empty?)
        [question[:question] || question["question"] || request.prompt, options]
      end

      def callback_data(request_id, choice)
        "kward:#{request_id}:#{choice}"
      end

      def split_message(text)
        text.each_char.each_slice(TELEGRAM_MESSAGE_LIMIT).map(&:join)
      end

      def allowed?(user_id, chat_id)
        @allowed_user_ids.include?(user_id) && @allowed_chat_ids.include?(chat_id)
      end

      def stopping?
        @state_mutex.synchronize { @stop }
      end

      def wait_for(seconds)
        @sleeper.call(seconds) unless stopping?
      end

      def record_error(error)
        message = error.message.to_s.gsub(@token.to_s, "[REDACTED]")
        summary = "#{error.class}: #{message}"
        @state_mutex.synchronize { @last_error = summary }
        @host.logger.error("Telegram transport error: #{summary}")
      rescue StandardError
        nil
      end

      def required_config(key)
        value = @config[key] || @config[key.to_sym]
        raise ArgumentError, "Telegram transport requires #{key}" if value.to_s.empty?

        value.to_s
      end

      def required_ids(key)
        values = @config[key] || @config[key.to_sym]
        values = Array(values).map { |value| Integer(value) }
        raise ArgumentError, "Telegram transport requires non-empty #{key}" if values.empty?

        values.uniq.freeze
      rescue ArgumentError, TypeError
        raise ArgumentError, "Telegram transport #{key} must contain numeric IDs"
      end
    end
  end
end
