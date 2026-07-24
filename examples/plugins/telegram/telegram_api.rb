require "json"
require "net/http"
require "uri"

module Kward
  module Telegram
    # Small dependency-free client for the Telegram Bot API.
    class BotApi
      API_BASE_URL = "https://api.telegram.org".freeze
      MAX_RESPONSE_BYTES = 5 * 1024 * 1024

      class Error < StandardError
        attr_reader :method, :error_code, :parameters

        def initialize(method, description, error_code: nil, parameters: nil)
          @method = method
          @error_code = error_code
          @parameters = parameters
          super("Telegram #{method} failed: #{description.to_s}")
        end
      end

      class RateLimitError < Error
        attr_reader :retry_after

        def initialize(method, description, retry_after:, error_code: nil, parameters: nil)
          @retry_after = Integer(retry_after)
          super(method, description, error_code: error_code, parameters: parameters)
        end
      end

      def initialize(token:, requester: nil, base_url: API_BASE_URL)
        @token = token.to_s
        raise ArgumentError, "Telegram bot token is required" if @token.empty?

        @requester = requester || method(:request)
        @base_url = base_url.to_s.sub(%r{/\z}, "")
      end

      def get_me
        call("getMe")
      end

      def delete_webhook(drop_pending_updates: false)
        call("deleteWebhook", "drop_pending_updates" => !!drop_pending_updates)
      end

      def get_updates(offset: nil, timeout: 25)
        timeout = Integer(timeout)
        raise ArgumentError, "Telegram polling timeout must be between 0 and 50 seconds" unless (0..50).cover?(timeout)

        params = {
          "timeout" => timeout,
          "allowed_updates" => JSON.generate(%w[message callback_query])
        }
        params["offset"] = Integer(offset) unless offset.nil?
        Array(call("getUpdates", params))
      end

      def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
        params = {
          "callback_query_id" => callback_query_id.to_s,
          "show_alert" => !!show_alert
        }
        params["text"] = text.to_s unless text.nil?
        call("answerCallbackQuery", params)
      end

      def send_message(chat_id:, text:, reply_to_message_id: nil, reply_markup: nil)
        text = text.to_s
        raise ArgumentError, "Telegram message text is required" if text.empty?

        params = { "chat_id" => Integer(chat_id), "text" => text }
        unless reply_to_message_id.nil?
          params["reply_parameters"] = JSON.generate({ "message_id" => Integer(reply_to_message_id) })
        end
        params["reply_markup"] = JSON.generate(reply_markup) unless reply_markup.nil?
        call("sendMessage", params)
      end

      private

      def call(method, params = {})
        response = @requester.call(method, params)
        unless response.is_a?(Hash) && response["ok"]
          raise_error(method, response || {})
        end

        response["result"]
      end

      def raise_error(method, response)
        description = (response["description"] || "unknown API error").to_s.gsub(@token, "[REDACTED]")
        parameters = response["parameters"] || {}
        if response["error_code"].to_i == 429 && parameters["retry_after"]
          raise RateLimitError.new(
            method,
            description,
            retry_after: parameters.fetch("retry_after"),
            error_code: response["error_code"],
            parameters: parameters
          )
        end

        raise Error.new(
          method,
          description,
          error_code: response["error_code"],
          parameters: parameters
        )
      end

      def request(method, params)
        uri = URI.parse("#{@base_url}/bot#{@token}/#{method}")
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(params.transform_values(&:to_s))

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 5,
          read_timeout: params.fetch("timeout", 10).to_i + 10
        ) { |http| http.request(request) }
        body = response.body.to_s
        raise Error.new(method, "response was too large") if body.bytesize > MAX_RESPONSE_BYTES

        JSON.parse(body)
      rescue JSON::ParserError
        raise Error.new(method, "response was not valid JSON")
      rescue URI::InvalidURIError
        raise Error.new(method, "invalid Telegram API URL")
      end
    end
  end
end
