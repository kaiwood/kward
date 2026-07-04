require_relative "../config_files"
require_relative "client"
require_relative "stdio_transport"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model Context Protocol client support.
  module MCP
    # Builds MCP clients from Kward configuration.
    module ServerConfig
      module_function

      def clients_from_config(config)
        servers = ConfigFiles.mcp_servers(config)

        servers.filter_map do |name, settings|
          client_from_settings(name, settings)
        end
      end

      def client_from_settings(name, settings)
        return nil unless settings.is_a?(Hash)
        return nil if settings["enabled"] == false

        command = settings["command"].to_s
        return nil if command.empty?

        Client.new(
          name: name,
          transport: StdioTransport.new(
            command: command,
            args: settings["args"] || [],
            env: normalized_env(settings["env"]),
            timeout_seconds: positive_number(settings["timeout_seconds"] || settings["timeoutSeconds"])
          )
        )
      end

      def normalized_env(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, item), env|
          env[key.to_s] = item.to_s
        end
      end

      def positive_number(value)
        number = value.to_f
        number.positive? ? number : nil
      rescue StandardError
        nil
      end
    end
  end
end
