require "securerandom"
require "time"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Immutable lifecycle event delivered to hook handlers.
    class Event
      attr_reader :id, :name, :phase, :timestamp, :session, :turn, :workspace, :frontend, :agent, :payload

      def initialize(name:, phase: nil, timestamp: Time.now.utc, session: nil, turn: nil, workspace: nil, frontend: nil, agent: nil, payload: nil, id: nil)
        @id = id || "hookevt_#{SecureRandom.hex(12)}"
        @name = name.to_s
        @phase = phase&.to_s || inferred_phase(@name)
        @timestamp = timestamp.is_a?(Time) ? timestamp.utc : Time.parse(timestamp.to_s).utc
        @session = deep_freeze(deep_dup(session || {}))
        @turn = deep_freeze(deep_dup(turn || {}))
        @workspace = deep_freeze(deep_dup(workspace || {}))
        @frontend = deep_freeze(deep_dup(frontend || {}))
        @agent = deep_freeze(deep_dup(agent || {}))
        @payload = deep_freeze(deep_dup(payload || {}))
        freeze
      end

      def [](key)
        payload[key] || payload[key.to_s]
      end

      def to_h
        {
          id: id,
          name: name,
          phase: phase,
          timestamp: timestamp.iso8601,
          session: session,
          turn: turn,
          workspace: workspace,
          frontend: frontend,
          agent: agent,
          payload: payload
        }
      end

      private

      def inferred_phase(name)
        return "before" if name.end_with?("_before") || name.include?("before_")
        return "after" if name.end_with?("_after") || name.include?("after_")
        return "error" if name.end_with?("_error") || name == "error"

        "during"
      end

      def deep_dup(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key] = deep_dup(item) }
        when Array
          value.map { |item| deep_dup(item) }
        else
          value.dup
        end
      rescue TypeError
        value
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |item| deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
