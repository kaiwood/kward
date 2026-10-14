require "json"
require "net/http"
require "uri"
require_relative "../auth/openai_oauth"
require_relative "../cancellation"

module Kward
  # Minimal supported client for ChatGPT-plan inference through Responses API.
  class PluginCodexResponses
    ENDPOINT = URI("https://api.openai.com/v1/responses")
    READ_TIMEOUT_SECONDS = 120

    class AuthenticationError < StandardError; end

    class RequestError < StandardError
      attr_reader :status

      def initialize(status)
        @status = status.to_i
        super("Codex Responses request failed (HTTP #{@status})")
      end
    end

    def initialize(oauth: OpenAIOAuth.new, endpoint: ENDPOINT)
      @oauth = oauth
      @endpoint = URI(endpoint.to_s)
    end

    # Streams parsed Responses API events to the caller and returns after a
    # terminal response event. The OAuth credential is never returned.
    def stream(model:, input:, instructions: nil, text: nil, max_output_tokens: nil, cancellation: nil)
      token = @oauth.access_token
      raise AuthenticationError, "No OpenAI OAuth login found. Run `kward login`." if token.to_s.empty?

      body = { model: model, input: input, store: false, stream: true }
      body[:instructions] = instructions unless instructions.nil?
      body[:text] = text unless text.nil?
      body[:max_output_tokens] = max_output_tokens if max_output_tokens
      request = Net::HTTP::Post.new(@endpoint)
      request["Authorization"] = "Bearer #{token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      request.body = JSON.generate(body)

      terminal = false
      Net::HTTP.start(@endpoint.hostname, @endpoint.port, use_ssl: @endpoint.scheme == "https", read_timeout: READ_TIMEOUT_SECONDS) do |http|
        cancellation&.on_cancel { close_http(http) }
        cancellation&.raise_if_cancelled!
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            response.read_body { |_chunk| }
            raise RequestError, response.code
          end

          parse_events(response, cancellation: cancellation) do |event|
            yield event
            terminal = %w[response.completed response.failed response.incomplete].include?(event["type"])
          end
        end
      end
      cancellation&.raise_if_cancelled!
      raise StreamError, "Codex Responses stream ended without a terminal event" unless terminal

      nil
    rescue IOError, SystemCallError, Timeout::Error
      raise Cancellation::CancelledError, "cancelled" if cancellation&.cancelled?

      raise RequestError, 502
    end

    private

    class StreamError < StandardError; end

    def parse_events(response, cancellation:)
      buffer = +""
      response.read_body do |chunk|
        cancellation&.raise_if_cancelled!
        buffer << chunk
        while (boundary = buffer.index(/\r?\n\r?\n/))
          block = buffer.slice!(0, boundary)
          buffer.slice!(/\A\r?\n\r?\n/)
          event = event_from_block(block)
          yield event if event
        end
      end
      event = event_from_block(buffer)
      yield event if event
    end

    def event_from_block(block)
      data = block.each_line.filter_map do |line|
        line = line.chomp
        line = line.delete_suffix("\r")
        line.delete_prefix("data:").sub(/\A /, "") if line.start_with?("data:")
      end
      return if data.empty?

      JSON.parse(data.join("\n"))
    rescue JSON::ParserError
      raise StreamError, "Codex Responses stream contained invalid JSON"
    end

    def close_http(http)
      http.finish if http&.started?
    rescue IOError
      nil
    end
  end
end
