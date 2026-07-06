require "json"
require "net/http"
require "uri"
require_relative "catalog"
require_relative "decision"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Executes an HTTP lifecycle hook using JSON request/response bodies.
    class HttpHandler
      DEFAULT_TIMEOUT_SECONDS = 10

      def initialize(url:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, headers: nil, failure_policy: Catalog::DEFAULT_FAILURE_POLICY, http_client: Net::HTTP)
        @uri = URI.parse(url.to_s)
        raise ArgumentError, "HTTP hook requires http or https URL" unless %w[http https].include?(@uri.scheme)

        @timeout_seconds = positive_timeout(timeout_seconds)
        @headers = stringify_hash(headers || {})
        @failure_policy = Catalog.normalize_failure_policy(failure_policy)
        @http_client = http_client
      end

      def call(event, _context = nil)
        response = post(JSON.dump(event.to_h))
        return failure_decision("HTTP hook failed: #{response.code} #{response.message}") unless response.is_a?(Net::HTTPSuccess)

        parse_decision(response.body)
      rescue StandardError => e
        failure_decision("HTTP hook failed: #{e.message}")
      end

      private

      def post(body)
        request = Net::HTTP::Post.new(@uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        @headers.each { |key, value| request[key] = value }
        request.body = body

        @http_client.start(@uri.hostname, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: @timeout_seconds, read_timeout: @timeout_seconds) do |http|
          http.request(request)
        end
      end

      def parse_decision(body)
        text = body.to_s.strip
        return Decision.allow if text.empty?

        Decision.normalize(JSON.parse(text))
      rescue JSON::ParserError => e
        failure_decision("HTTP hook returned invalid JSON: #{e.message}")
      end

      def failure_decision(message)
        Catalog.failure_decision(@failure_policy, message)
      end

      def positive_timeout(value)
        seconds = value.to_i
        seconds.positive? ? seconds : DEFAULT_TIMEOUT_SECONDS
      end

      def stringify_hash(value)
        value.each_with_object({}) do |(key, item), result|
          result[key.to_s] = item.to_s
        end
      end
    end
  end
end
