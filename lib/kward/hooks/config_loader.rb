require_relative "catalog"
require_relative "command_handler"
require_relative "manager"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Builds hook managers from Kward configuration hashes.
    class ConfigLoader
      def initialize(config)
        @config = config || {}
      end

      def manager
        Manager.new.tap do |manager|
          hooks_config.each do |event, entries|
            Array(entries).each_with_index do |entry, index|
              register_entry(manager, event.to_s, entry, index)
            end
          end
        end
      end

      private

      def hooks_config
        value = @config["hooks"] || @config[:hooks]
        value.is_a?(Hash) ? value : {}
      end

      def register_entry(manager, event, entry, index)
        entry = normalize_entry(entry)
        return if truthy?(entry["disabled"])

        handler = handler_for(entry)
        manager.register(
          event,
          id: entry["id"] || "config:#{event}:#{index + 1}",
          source: "config",
          order: entry.fetch("order", 100),
          match: entry["match"],
          failure_policy: entry["failure_policy"]
        ) { |hook_event, context| handler.call(hook_event, context) }
      end

      def normalize_entry(entry)
        case entry
        when String
          { "type" => "command", "command" => entry }
        when Hash
          entry.transform_keys(&:to_s)
        else
          raise ArgumentError, "Invalid hook config entry: #{entry.inspect}"
        end
      end

      def handler_for(entry)
        type = (entry["type"] || "command").to_s
        case type
        when "command"
          CommandHandler.new(
            command: required(entry, "command"),
            timeout_seconds: entry["timeout_seconds"],
            env: entry["env"],
            failure_policy: entry["failure_policy"] || Catalog::DEFAULT_FAILURE_POLICY
          )
        else
          raise ArgumentError, "Unsupported hook type: #{type}"
        end
      end

      def required(entry, key)
        value = entry[key]
        raise ArgumentError, "Hook config requires #{key}" if value.to_s.empty?

        value
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end
    end
  end
end
