require "thread"
require "time"
require_relative "host"

module Kward
  module Transport
    # Starts and supervises registered transport adapters.
    class Manager
      Entry = Struct.new(:type, :host, :adapter, :state, :error, :started_at, :stopped_at, keyword_init: true)

      def initialize(registry:, gateway: nil, config_root: nil, policy: nil, logger: nil)
        @registry = registry
        @gateway = gateway
        @config_root = config_root
        @policy = policy
        @logger = logger || Logger.new($stderr)
        @entries = {}
        @mutex = Mutex.new
      end

      def list
        @registry.transports.map { |type| descriptor(type) }
      end

      def status(name_or_id = nil)
        return status_for(resolve_type(name_or_id)) if name_or_id

        list.map { |type| status_for(type) }
      end

      def start(name_or_id, config: {})
        type = resolve_type(name_or_id)
        @mutex.synchronize do
          raise "Transport #{type.id} is already running" if running_entry?(type.id)
        end

        host = Host.new(
          transport_id: type.id,
          gateway: @gateway,
          config: config,
          storage: @config_root && Store.new(type.id, root: @config_root),
          policy: @policy,
          logger: @logger
        )
        adapter = type.handler.call(host, host.config)
        unless adapter.respond_to?(:start) && adapter.respond_to?(:stop)
          raise "Transport #{type.id} must implement start and stop"
        end

        entry = Entry.new(type: type, host: host, adapter: adapter, state: "starting")
        @mutex.synchronize { @entries[type.id] = entry }
        begin
          adapter.start
          @mutex.synchronize do
            entry.state = "running"
            entry.started_at = Time.now.utc
            entry.error = nil
          end
          adapter
        rescue StandardError => e
          @mutex.synchronize do
            entry.state = "failed"
            entry.error = e.message
            entry.stopped_at = Time.now.utc
          end
          log_error(type, e)
          raise
        end
      end

      def stop(name_or_id)
        type = resolve_type(name_or_id)
        entry = @mutex.synchronize { @entries[type.id] }
        return false unless entry

        begin
          entry.adapter.stop
        ensure
          @mutex.synchronize do
            entry.state = "stopped"
            entry.stopped_at = Time.now.utc
          end
        end
        true
      end

      def restart(name_or_id, config: {})
        stop(name_or_id)
        start(name_or_id, config: config)
      end

      def shutdown
        entries = @mutex.synchronize { @entries.values.dup }
        entries.each { |entry| stop(entry.type.id) if entry.state == "running" || entry.state == "starting" }
        nil
      end

      private

      def resolve_type(name_or_id)
        type = @registry.transport_for(name_or_id) || @registry.transport_for_id(name_or_id)
        raise ArgumentError, "Unknown transport: #{name_or_id}" unless type

        type
      end

      def running_entry?(id)
        entry = @entries[id]
        entry && %w[starting running].include?(entry.state)
      end

      def descriptor(type)
        {
          id: type.id,
          name: type.name,
          capabilities: type.capabilities,
          path: type.path
        }
      end

      def status_for(type)
        entry = @mutex.synchronize { @entries[type.id] }
        descriptor(type).merge(
          state: entry&.state || "stopped",
          error: entry&.error,
          started_at: entry&.started_at,
          stopped_at: entry&.stopped_at
        )
      end

      def log_error(type, error)
        @logger.error("Transport #{type.id} failed to start: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end
    end
  end
end
