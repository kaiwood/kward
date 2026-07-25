require "thread"
require "time"
require_relative "host"

module Kward
  module Transport
    # Starts and supervises registered transport adapters.
    class Manager
      Entry = Struct.new(:type, :host, :adapter, :state, :error, :started_at, :stopped_at, keyword_init: true)

      def initialize(registry:, gateway: nil, plugin_chat_gateway: nil, config_root: nil, config_provider: nil, policy: nil, logger: nil)
        @registry = registry
        @gateway = gateway
        @plugin_chat_gateway = plugin_chat_gateway
        @config_root = config_root
        @config_provider = config_provider
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

      def start(name_or_id, config: nil, workspace_root: nil)
        type = resolve_type(name_or_id)
        @mutex.synchronize do
          raise "Transport #{type.id} is already running" if running_entry?(type.id)
        end

        config ||= @config_provider&.call(type.id) || {}
        config = config.merge("workspace" => workspace_root.to_s) if workspace_root
        gateway = @gateway.respond_to?(:call) ? @gateway.call(type.id) : @gateway
        plugin_chat_gateway = @plugin_chat_gateway.respond_to?(:call) ? @plugin_chat_gateway.call(type.id) : @plugin_chat_gateway
        host = Host.new(
          transport_id: type.id,
          gateway: gateway,
          plugin_chat_gateway: plugin_chat_gateway,
          config: config,
          storage: @config_root && Store.new(type.id, root: @config_root),
          policy: @policy,
          logger: @logger,
          execution_profile: type.execution_profile
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
          entry.host.shutdown
          @mutex.synchronize do
            entry.state = "stopped"
            entry.stopped_at = Time.now.utc
          end
        end
        true
      end

      def restart(name_or_id, config: nil)
        stop(name_or_id)
        start(name_or_id, config: config)
      end

      def reload(registry)
        shutdown
        @mutex.synchronize { @registry = registry }
        list
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
          capabilities: type.capabilities.to_h,
          execution_profile: profile_payload(type.execution_profile),
          path: type.path
        }
      end

      def status_for(type)
        entry = @mutex.synchronize { @entries[type.id] }
        descriptor(type).merge(
          state: entry&.state || "stopped",
          error: entry&.error,
          health: health_for(entry),
          started_at: entry&.started_at,
          stopped_at: entry&.stopped_at
        )
      end

      def profile_payload(profile)
        return nil unless profile

        {
          id: profile.id,
          tool_mode: profile.tool_mode,
          allowed_tools: profile.allowed_tools,
          disabled_tools: profile.disabled_tools,
          plugin_commands: profile.plugin_commands,
          approval_mode: profile.approval_mode,
          memory: profile.memory,
          attachments: profile.attachments,
          workspace_mode: profile.workspace_mode
        }
      end

      def health_for(entry)
        return nil unless entry&.adapter&.respond_to?(:health)

        entry.adapter.health
      rescue StandardError => e
        { state: "error", message: e.message }
      end

      def log_error(type, error)
        @logger.error("Transport #{type.id} failed to start: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end
    end
  end
end
