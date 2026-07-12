require "uri"

# Namespace for Kward's permission-policy runtime.
module Kward
  module Permissions
    # Evaluates the opt-in permission policy for model-requested tool calls.
    #
    # The policy is intentionally a decision layer, not a process sandbox. It
    # can prevent Kward from starting a tool, but it cannot constrain a shell
    # command after it has begun. OS-enforced sandboxing belongs at a lower
    # process boundary.
    class Policy
      MODES = %w[ask read-only workspace-write deny-by-default].freeze
      NETWORK_TOOLS = %w[web_search fetch_content fetch_raw].freeze
      FILE_CHANGE_TOOLS = %w[write_file edit_file].freeze

      Decision = Struct.new(:action, :reason, keyword_init: true) do
        def allowed?
          action == :allow
        end

        def approval_required?
          action == :ask
        end

        def denied?
          action == :deny
        end
      end

      def self.from_config(config)
        permissions = config["permissions"].is_a?(Hash) ? config["permissions"] : {}
        new(
          enabled: permissions["enabled"] == true,
          mode: permissions["mode"],
          allow: permissions["allow"],
          ask: permissions["ask"],
          deny: permissions["deny"],
          write_scopes: permissions.key?("write_scopes") ? permissions["write_scopes"] : nil
        )
      end

      def initialize(enabled: false, mode: "ask", allow: [], ask: [], deny: [], write_scopes: nil)
        @enabled = enabled == true
        @mode = normalize_mode(mode)
        @allow = normalize_rules(allow)
        @ask = normalize_rules(ask)
        @deny = normalize_rules(deny)
        @write_scopes = normalize_scopes(write_scopes)
        @session_allowed_tools = {}
      end

      def enabled?
        @enabled
      end

      # Allows this model tool for the remaining lifetime of this policy object.
      # A matching deny or ask rule still takes precedence over this temporary grant.
      def allow_for_session!(tool_name)
        @session_allowed_tools[tool_name.to_s] = true
      end

      def decision_for(tool_name, arguments, source: nil)
        return Decision.new(action: :allow, reason: "permissions disabled") unless enabled?

        request = request_for(tool_name, arguments, source: source)
        return Decision.new(action: :deny, reason: "matched deny rule") if matches?(@deny, request)
        return Decision.new(action: :ask, reason: "matched ask rule") if matches?(@ask, request)
        return Decision.new(action: :allow, reason: "matched allow rule") if matches?(@allow, request)
        return Decision.new(action: :allow, reason: "allowed for this session") if @session_allowed_tools[request.fetch("tool")]

        default_decision(request)
      end

      private

      def normalize_mode(mode)
        value = mode.to_s
        MODES.include?(value) ? value : "ask"
      end

      def normalize_rules(rules)
        Array(rules).filter_map do |rule|
          next unless rule.is_a?(Hash)

          rule.transform_keys(&:to_s).slice("tool", "path", "host", "command", "source")
        end
      end

      def normalize_scopes(scopes)
        return nil if scopes.nil?

        Array(scopes).map(&:to_s).reject(&:empty?)
      end

      def request_for(tool_name, arguments, source:)
        name = tool_name.to_s
        args = arguments.to_h
        {
          "tool" => name,
          "path" => args["path"] || args[:path],
          "host" => request_host(name, args),
          "command" => args["command"] || args[:command],
          "source" => source.to_s
        }.compact.transform_values(&:to_s)
      end

      def request_host(name, arguments)
        return nil unless %w[fetch_content fetch_raw].include?(name)

        URI.parse((arguments["url"] || arguments[:url]).to_s).host
      rescue URI::InvalidURIError
        nil
      end

      def matches?(rules, request)
        rules.any? { |rule| rule_matches?(rule, request) }
      end

      def rule_matches?(rule, request)
        return false if rule.empty?

        rule.all? do |field, pattern|
          value = request[field]
          value && glob_match?(pattern.to_s, value)
        end
      end

      def glob_match?(pattern, value)
        expression = Regexp.escape(pattern).gsub("\\*\\*", ".*").gsub("\\*", "[^/]*")
        Regexp.new("\\A#{expression}\\z").match?(value)
      end

      def default_decision(request)
        return Decision.new(action: :deny, reason: "read-only mode") if @mode == "read-only" && risky?(request)
        return Decision.new(action: :deny, reason: "deny-by-default mode") if @mode == "deny-by-default" && risky?(request)

        if file_change?(request) && outside_write_scopes?(request)
          return Decision.new(action: :deny, reason: "path outside write scopes")
        end

        if @mode == "workspace-write" && file_change?(request)
          return Decision.new(action: :allow, reason: "workspace write mode")
        end

        return Decision.new(action: :allow, reason: "read-only tool") unless risky?(request)

        Decision.new(action: :ask, reason: "#{request.fetch("tool")} requires approval")
      end

      def file_change?(request)
        FILE_CHANGE_TOOLS.include?(request.fetch("tool"))
      end

      def network?(request)
        NETWORK_TOOLS.include?(request.fetch("tool")) || request["source"] == "mcp"
      end

      def risky?(request)
        file_change?(request) || request.fetch("tool") == "run_shell_command" || network?(request)
      end

      def outside_write_scopes?(request)
        return false if @write_scopes.nil?

        path = request["path"]
        path.nil? || !@write_scopes.any? { |scope| glob_match?(scope, path) }
      end
    end
  end
end
