require "json"
require "open3"
require "shellwords"
require "timeout"
require_relative "catalog"
require_relative "decision"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Executes an external command hook using JSON over stdin/stdout.
    class CommandHandler
      DEFAULT_TIMEOUT_SECONDS = 10

      def initialize(command:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, env: nil, failure_policy: Catalog::DEFAULT_FAILURE_POLICY)
        @command = command.to_s
        @timeout_seconds = positive_timeout(timeout_seconds)
        @env = stringify_hash(env || {})
        @failure_policy = Catalog.normalize_failure_policy(failure_policy)
      end

      def call(event, _context = nil)
        stdout, stderr, status = run_command(JSON.dump(event.to_h))
        return failure_decision("Command hook failed: #{stderr.strip.empty? ? "exit #{status.exitstatus}" : stderr.strip}") unless status.success?

        parse_decision(stdout)
      rescue Timeout::Error
        failure_decision("Command hook timed out after #{@timeout_seconds}s")
      rescue StandardError => e
        failure_decision("Command hook failed: #{e.message}")
      end

      private

      def run_command(input)
        Timeout.timeout(@timeout_seconds) do
          Open3.capture3(@env, *@command.shellsplit, stdin_data: input)
        end
      end

      def parse_decision(stdout)
        text = stdout.to_s.strip
        return Decision.allow if text.empty?

        Decision.normalize(JSON.parse(text))
      rescue JSON::ParserError => e
        failure_decision("Command hook returned invalid JSON: #{e.message}")
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
