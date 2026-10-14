require "json"
require "thread"
require_relative "protocol"

module Kward
  module OpenRouterProxy
    class Server
      ENDPOINT_PATH = "/api/v1/chat/completions"
      DEFAULT_PORT = 4000
      DEFAULT_MAX_BODY_BYTES = 1_048_576
      MAX_NONSTREAM_EVENTS = 100_000

      def initialize(host:, codex: host.codex_responses, output: $stderr)
        @host = host
        @codex = codex
        @output = output
        @config = host.config
        model_map = @config.fetch("model_map", {})
        raise ArgumentError, "Configure at least one proxy model mapping" unless model_map.is_a?(Hash) && !model_map.empty?

        @protocol = Protocol.new(model_map: model_map)
        @api_key = host.secret("api_key")
        raise ArgumentError, "Configure the proxy api_key secret before starting" if @api_key.to_s.empty?
      end

      def run
        listener = @host.http_server(
          host: "127.0.0.1",
          port: integer_config("port", DEFAULT_PORT, min: 0, max: 65_535),
          max_body_bytes: integer_config("max_body_bytes", DEFAULT_MAX_BODY_BYTES, min: 1024, max: 16_777_216)
        ) { |request, response| handle(request, response) }
        listener.start
        @output.puts("OpenRouter-compatible proxy listening at http://127.0.0.1:#{listener.port}/api/v1")
        listener.wait
      ensure
        listener&.stop
      end

      def handle(request, response)
        return unauthorized(response) unless authorized?(request)
        return write_error(response, 404, "Not found", "not_found") unless request.path == ENDPOINT_PATH
        return write_error(response, 405, "Method not allowed", "method_not_allowed") unless request.request_method == "POST"
        return write_error(response, 415, "Content-Type must be application/json", "invalid_content_type") unless request["content-type"].to_s.downcase.start_with?("application/json")

        payload = JSON.parse(request.body.to_s)
        parsed = @protocol.parse_request(payload)
        parsed.stream ? handle_stream(parsed, response) : handle_nonstream(parsed, response)
      rescue JSON::ParserError
        write_error(response, 400, "Invalid JSON request body", "invalid_json")
      rescue RequestError => error
        write_error(response, error.status, error.message, error.status >= 500 ? "upstream_error" : "invalid_request")
      rescue PluginCodexResponses::AuthenticationError
        write_error(response, 503, "Kward Codex authentication is unavailable", "upstream_authentication_error")
      rescue PluginCodexResponses::RequestError => error
        write_error(response, 502, error.message, "upstream_error")
      rescue Cancellation::CancelledError
        nil
      rescue StandardError
        write_error(response, 502, "Codex request failed", "upstream_error")
      end

      private

      def handle_nonstream(request, response)
        events = []
        @codex.stream(**@protocol.responses_request(request), max_output_tokens: request.max_output_tokens) do |event|
          events << event
          raise RequestError.new("Codex response exceeded the event limit", status: 502) if events.length > MAX_NONSTREAM_EVENTS
        end
        write_json(response, 200, @protocol.chat_completion(request, events))
      end

      def handle_stream(request, response)
        state = @protocol.stream_state(request)
        cancellation = Cancellation.new
        events = SizedQueue.new(16)
        worker = Thread.new do
          @codex.stream(**@protocol.responses_request(request), max_output_tokens: request.max_output_tokens, cancellation: cancellation) do |event|
            enqueue_stream_event(events, [:event, event], cancellation)
          end
          enqueue_stream_event(events, [:done, nil], cancellation)
        rescue StandardError => error
          enqueue_stream_event(events, [:error, error], cancellation) unless cancellation.cancelled?
        end
        worker.report_on_exception = false

        first = events.pop
        if first.first == :error
          worker.join
          raise first.last
        end

        response.status = 200
        response["Content-Type"] = "text/event-stream"
        response["Cache-Control"] = "no-cache"
        response["X-Accel-Buffering"] = "no"
        response.chunked = true
        response.body = proc do |output|
          output.write(sse(@protocol.stream_start_chunk(state)))
          done = false
          current = first
          until done
            kind, event = current
            case kind
            when :event
              chunks = @protocol.stream_chunks(state, event)
              chunks.each { |chunk| output.write(sse(chunk)) }
              done = state[:terminal]
            when :done
              done = true
            when :error
              state[:failed] = true
              output.write(sse(@protocol.stream_chunks(state, "type" => "response.failed").first))
              done = true
            end
            current = events.pop unless done
          end
          output.write("data: [DONE]\n\n") unless state[:failed]
        ensure
          cancellation.cancel! unless state[:terminal]
          worker.join(2)
        end
      end

      def enqueue_stream_event(queue, event, cancellation)
        loop do
          cancellation.raise_if_cancelled!
          queue.push(event, true)
          return
        rescue ThreadError
          sleep 0.01
        end
      end

      def authorized?(request)
        authorization = request["authorization"].to_s
        return false unless authorization.start_with?("Bearer ")

        secure_compare(authorization.delete_prefix("Bearer "), @api_key)
      end

      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
      end

      def unauthorized(response)
        response["WWW-Authenticate"] = 'Bearer realm="Kward OpenRouter proxy"'
        write_error(response, 401, "Unauthorized", "invalid_api_key")
      end

      def write_json(response, status, payload)
        response.status = status
        response["Content-Type"] = "application/json"
        response["Cache-Control"] = "no-store"
        response.body = JSON.generate(payload)
      end

      def write_error(response, status, message, code)
        write_json(response, status, { error: { message: message, type: "invalid_request_error", code: code } })
      end

      def sse(chunk)
        "data: #{JSON.generate(chunk)}\n\n"
      end

      def integer_config(key, default, min:, max:)
        value = @config.fetch(key, default)
        integer = Integer(value)
        raise ArgumentError, "Proxy config #{key} must be between #{min} and #{max}" unless integer.between?(min, max)

        integer
      rescue ArgumentError, TypeError
        raise ArgumentError, "Proxy config #{key} must be an integer between #{min} and #{max}"
      end
    end
  end
end
