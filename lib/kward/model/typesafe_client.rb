require "json"
require "net/http"
require "uri"
require_relative "../cancellation"
require_relative "../http"

module Kward
  # HTTP client for TypeSafe's structured System One evaluation endpoint.
  class TypeSafeClient
    DEFAULT_ENDPOINT = "https://api.typesafe.ai/v1/systemone"
    DEFAULT_MODEL = "jev-latest"
    MAX_STATE_BYTES = 100_000
    MAX_QUESTIONS = 100
    HTTP_TIMEOUT_SECONDS = 30

    class RequestError < StandardError
      attr_reader :status

      def initialize(status:, message:)
        @status = status.to_i
        super(message)
      end
    end

    def initialize(api_key: ENV["TYPESAFE_API_KEY"], endpoint: DEFAULT_ENDPOINT, http: Net::HTTP)
      @api_key = api_key.to_s.strip
      @endpoint = URI(endpoint)
      @http = http
    end

    def available?
      !@api_key.empty?
    end

    def evaluate(state:, questions:, model: DEFAULT_MODEL, cancellation: nil)
      raise ArgumentError, "TypeSafe API key is not configured" unless available?

      cancellation&.raise_if_cancelled!
      request = Net::HTTP::Post.new(@endpoint)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      Http.apply_user_agent(request)
      request.body = JSON.dump({ state: state, model: model, questions: questions })

      response_body = nil
      @http.start(@endpoint.hostname, @endpoint.port, use_ssl: @endpoint.scheme == "https", read_timeout: HTTP_TIMEOUT_SECONDS) do |http|
        cancellation&.on_cancel { close_http(http) }
        cancellation&.raise_if_cancelled!
        response = http.request(request)
        response_body = response.body.to_s
        unless response.is_a?(Net::HTTPSuccess)
          raise RequestError.new(status: response.code, message: error_message(response.code, response_body))
        end
      end
      cancellation&.raise_if_cancelled!
      JSON.parse(response_body)
    rescue JSON::ParserError
      raise RequestError.new(status: 200, message: "TypeSafe returned invalid JSON")
    end

    private

    def error_message(status, body)
      detail = JSON.parse(body).fetch("error", nil) rescue nil
      detail = detail["message"] if detail.is_a?(Hash)
      detail = detail.to_s unless detail.nil?
      detail = "request failed" if detail.nil? || detail.empty?
      "TypeSafe request failed (#{status}): #{detail[0, 500]}"
    end

    def close_http(http)
      http.finish if http&.started?
    rescue IOError
      nil
    end
  end
end
