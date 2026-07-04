require_relative "stdio_transport"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Model Context Protocol client support.
  module MCP
    PROTOCOL_VERSION = "2025-11-25"

    # Minimal MCP client for discovering and invoking server tools.
    class Client
      attr_reader :name

      def initialize(name:, transport:)
        @name = name.to_s
        @transport = transport
        @initialized = false
      end

      def initialize!
        return if @initialized

        @transport.request("initialize", initialize_params)
        @transport.notify("notifications/initialized")
        @initialized = true
      end

      def list_tools
        initialize!
        result = @transport.request("tools/list", {})
        Array(result["tools"] || result[:tools])
      end

      def call_tool(name, arguments = {})
        initialize!
        @transport.request("tools/call", { name: name, arguments: arguments || {} })
      end

      def close
        @transport.close
      end

      private

      def initialize_params
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: {
            name: "kward",
            version: Kward.const_defined?(:VERSION) ? Kward::VERSION : "0.0.0"
          }
        }
      end
    end
  end
end
