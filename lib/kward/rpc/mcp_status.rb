require_relative "../mcp/server_config"
require_relative "redactor"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # Builds RPC-visible MCP server status payloads.
    class MCPStatus
      def initialize(config_manager:)
        @config_manager = config_manager
      end

      def to_h
        config = @config_manager.read(redacted: false)
        clients = MCP::ServerConfig.clients_from_config(config).to_h { |client| [client.name, client] }
        servers = MCP::ServerConfig.configured_servers(config).map do |name, settings|
          server_status(name, settings, clients[name.to_s])
        end
        { servers: servers }
      end

      private

      def server_status(name, settings, client)
        base = { name: name.to_s, transport: "stdio", toolCount: 0 }
        unless client
          return base.merge(status: "unavailable", error: "command not configured") if settings["command"].to_s.empty?

          return base.merge(status: "unavailable", error: "unsupported MCP server configuration")
        end

        tools = client.list_tools
        base.merge(status: "available", toolCount: tools.length)
      rescue StandardError => e
        base.merge(status: "unavailable", toolCount: 0, error: redacted_error(e.message, client))
      ensure
        client&.close
      end

      def redacted_error(message, client)
        text = Redactor.redact_string(message.to_s)
        command = client&.transport&.respond_to?(:command) ? client.transport.command.to_s : ""
        return text if command.empty?

        text.gsub(command, File.basename(command))
      end
    end
  end
end
