require_relative "audit_log"
require_relative "catalog"
require_relative "decision"
require_relative "event"
require_relative "matcher"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Dispatches lifecycle events to registered hooks and combines decisions.
    class Manager
      Handler = Struct.new(:id, :event, :source, :order, :match, :callback, :failure_policy, keyword_init: true)
      Result = Struct.new(:event, :decision, :decisions, :warnings, :messages, :payload, keyword_init: true) do
        def allowed?
          !decision.deny? && !decision.ask?
        end

        def denied?
          decision.deny?
        end

        def approval_required?
          decision.ask?
        end
      end

      attr_reader :handlers

      def initialize(audit_log: AuditLog.new)
        @handlers = []
        @audit_log = audit_log
      end

      def register(event, id: nil, source: nil, order: 100, match: nil, failure_policy: nil, &callback)
        raise ArgumentError, "Hook requires an event name" if event.to_s.empty?
        raise ArgumentError, "Hook requires a handler" unless callback

        handler = Handler.new(
          id: id || "#{source || "hook"}:#{event}:#{@handlers.length + 1}",
          event: event.to_s,
          source: source,
          order: order.to_i,
          match: Matcher.new(match),
          callback: callback,
          failure_policy: Catalog.failure_policy(event, failure_policy)
        )
        @handlers << handler
        handler
      end

      def empty?
        @handlers.empty?
      end

      def run(event, context: nil)
        event = normalize_event(event)
        decisions = []
        warnings = []
        messages = []
        payload = deep_dup(event.payload)

        handlers_for(event).each do |handler|
          decision = call_handler(handler, event, context)
          decisions << decision
          warnings << decision.message if decision.warning? && decision.message
          messages << decision.message if decision.message && !decision.warning?

          if decision.modify?
            modifications = Catalog.filter_modifications(event.name, decision.payload)
            payload = deep_merge(payload, modifications)
            event = event_with_payload(event, payload)
          end

          break if decision.deny?
        end

        final_decision = final_decision(decisions)
        result = Result.new(
          event: event,
          decision: final_decision,
          decisions: decisions,
          warnings: warnings,
          messages: messages,
          payload: payload
        )
        @audit_log&.log_result(event: event, result: result)
        result
      end

      private

      def normalize_event(event)
        return event if event.is_a?(Event)

        Event.new(**event)
      end

      def handlers_for(event)
        @handlers
          .select { |handler| handler.event == event.name && handler.match.match?(event) }
          .sort_by { |handler| [handler.order, handler.id.to_s] }
      end

      def call_handler(handler, event, context)
        started_at = @audit_log&.monotonic_now
        value = if handler.callback.arity == 1
                  handler.callback.call(event)
                else
                  handler.callback.call(event, context)
                end
        Decision.normalize(value).tap do |decision|
          log_handler(event, handler, decision, started_at)
        end
      rescue StandardError => e
        Catalog.failure_decision(
          handler.failure_policy,
          "Hook #{handler.id} failed: #{e.message}",
          metadata: { hook_id: handler.id, source: handler.source }
        ).tap do |decision|
          log_handler(event, handler, decision, started_at)
        end
      end

      def log_handler(event, handler, decision, started_at)
        @audit_log&.log_handler(
          event: event,
          handler: handler,
          decision: decision,
          duration_ms: started_at ? @audit_log.duration_ms(started_at) : nil
        )
      end

      def final_decision(decisions)
        decisions.find(&:deny?) || decisions.find(&:ask?) || decisions.reverse.find(&:modify?) || decisions.find(&:warning?) || Decision.allow
      end

      def event_with_payload(event, payload)
        Event.new(
          id: event.id,
          name: event.name,
          phase: event.phase,
          timestamp: event.timestamp,
          session: event.session,
          turn: event.turn,
          workspace: event.workspace,
          frontend: event.frontend,
          agent: event.agent,
          payload: payload
        )
      end

      def deep_merge(left, right)
        left = deep_dup(left)
        right.each do |key, value|
          left[key] = if left[key].is_a?(Hash) && value.is_a?(Hash)
                        deep_merge(left[key], value)
                      else
                        deep_dup(value)
                      end
        end
        left
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
    end
  end
end
