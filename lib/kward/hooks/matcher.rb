# Namespace for the Kward CLI agent runtime.
module Kward
  module Hooks
    # Matches lifecycle hook selectors against event payloads.
    class Matcher
      def initialize(match = nil)
        @match = match || {}
      end

      def match?(event)
        return true if @match.empty?

        @match.all? { |key, expected| matches_key?(event, key.to_s, expected) }
      end

      private

      def matches_key?(event, key, expected)
        case key
        when "event", "name"
          matches_value?(event.name, expected)
        when "phase"
          matches_value?(event.phase, expected)
        when "tool", "tool_name"
          matches_value?(payload_value(event, "tool_name") || payload_value(event, "tool"), expected)
        when "mcp_server", "server"
          matches_value?(payload_value(event, "server_name") || payload_value(event, "mcp_server"), expected)
        when "mcp_tool", "remote_name"
          matches_value?(payload_value(event, "remote_name") || payload_value(event, "mcp_tool"), expected)
        when "operation"
          matches_value?(payload_value(event, "operation"), expected)
        when "frontend"
          matches_value?(event.frontend[:name] || event.frontend["name"], expected)
        when "provider"
          matches_value?(event.agent[:provider] || event.agent["provider"], expected)
        when "model"
          matches_value?(event.agent[:model] || event.agent["model"], expected)
        when "path", "paths"
          matches_path?(payload_paths(event), expected)
        when "command_regex"
          value = payload_value(event, "command").to_s
          Array(expected).any? { |pattern| Regexp.new(pattern.to_s).match?(value) }
        else
          matches_value?(payload_value(event, key), expected)
        end
      end

      def payload_value(event, key)
        event.payload[key.to_sym] || event.payload[key]
      end

      def payload_paths(event)
        values = []
        values << payload_value(event, "path")
        values.concat(Array(payload_value(event, "paths")))
        Array(payload_value(event, "files")).each do |file|
          values << (file[:path] || file["path"]) if file.respond_to?(:[])
        end
        values.compact.map(&:to_s)
      end

      def matches_path?(paths, expected)
        patterns = Array(expected).map(&:to_s)
        paths.any? do |path|
          patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
        end
      end

      def matches_value?(actual, expected)
        expected_values = Array(expected).map(&:to_s)
        expected_values.include?(actual.to_s)
      end
    end
  end
end
