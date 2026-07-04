require "json"
require_relative "base"

# Namespace for the Kward CLI agent runtime.
module Kward
  module Tools
    # Adapts an MCP server tool to Kward's model-callable tool interface.
    class MCPTool < Base
      attr_reader :server_name, :remote_name

      def initialize(server_name:, client:, tool:)
        @server_name = server_name.to_s
        @client = client
        @tool = tool
        @remote_name = value(tool, "name").to_s
        super(kward_name(@server_name, @remote_name), description, properties: {}, required: [])
      end

      def schema
        {
          type: "function",
          function: {
            name: name,
            description: description,
            parameters: input_schema
          }
        }
      end

      def call(args, _conversation, cancellation: nil)
        cancellation&.raise_if_cancelled!
        result = @client.call_tool(@remote_name, args || {})
        format_result(result)
      rescue StandardError => e
        "MCP tool #{server_name}.#{remote_name} failed: #{e.message}"
      end

      def self.kward_name(server_name, tool_name)
        "#{sanitize_name(server_name)}__#{sanitize_name(tool_name)}"
      end

      def self.sanitize_name(value)
        text = value.to_s.gsub(/[^A-Za-z0-9_-]/, "_")
        text = "mcp" if text.empty?
        text[0, 60]
      end

      private

      def kward_name(server_name, tool_name)
        self.class.kward_name(server_name, tool_name)
      end

      def description
        value(@tool, "description").to_s.empty? ? "MCP tool #{@server_name}.#{@remote_name}" : value(@tool, "description").to_s
      end

      def input_schema
        schema = value(@tool, "inputSchema")
        return empty_object_schema unless schema.is_a?(Hash)

        schema.empty? ? empty_object_schema : schema
      end

      def empty_object_schema
        { type: "object", properties: {}, additionalProperties: false }
      end

      def format_result(result)
        return "MCP tool #{server_name}.#{remote_name} returned no content." unless result.is_a?(Hash)

        parts = []
        parts << "MCP tool #{server_name}.#{remote_name} reported an error:" if truthy?(value(result, "isError"))
        parts.concat(format_content(value(result, "content")))

        structured = value(result, "structuredContent")
        parts << JSON.pretty_generate(structured) unless structured.nil?

        parts.empty? ? "MCP tool #{server_name}.#{remote_name} returned no content." : parts.join("\n\n")
      end

      def format_content(content)
        Array(content).filter_map do |entry|
          next entry.to_s unless entry.is_a?(Hash)

          case value(entry, "type")
          when "text"
            value(entry, "text").to_s
          when "image"
            "[MCP image content: #{value(entry, "mimeType") || "unknown MIME type"}]"
          when "audio"
            "[MCP audio content: #{value(entry, "mimeType") || "unknown MIME type"}]"
          when "resource_link"
            "[MCP resource link: #{value(entry, "uri") || value(entry, "name") || "unnamed"}]"
          when "resource"
            "[MCP embedded resource: #{resource_label(value(entry, "resource"))}]"
          else
            JSON.generate(entry)
          end
        end
      end

      def resource_label(resource)
        return "unnamed" unless resource.is_a?(Hash)

        value(resource, "uri") || value(resource, "name") || "unnamed"
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end

      def value(object, key)
        object[key] || object[key.to_sym]
      end
    end
  end
end
