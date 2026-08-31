# Configuration settings behavior.
module Kward
  module ConfigFiles
    module Settings
      extend self

      def overlay_settings(config = read_config)
        overlay = config["overlay"].is_a?(Hash) ? config["overlay"] : {}
        settings = DEFAULT_OVERLAY_SETTINGS.dup
        alignment = overlay["alignment"].to_s
        width = overlay["width"].to_s
        settings["alignment"] = alignment if OVERLAY_ALIGNMENTS.include?(alignment)
        settings["width"] = width if OVERLAY_WIDTHS.include?(width)
        settings
      end

      # Returns the project browser icon theme, or off when unset or invalid.
      def project_browser_icon_theme(config = read_config)
        browser = config["project_browser"].is_a?(Hash) ? config["project_browser"] : {}
        theme = browser["icons"].to_s
        PROJECT_BROWSER_ICON_THEMES.include?(theme) ? theme : "off"
      end

      # Returns whether the composer should show busy-state keyboard help.
      def composer_busy_help?(config = read_config)
        composer = config["composer"].is_a?(Hash) ? config["composer"] : {}
        composer["busy_help"] != false
      end

      # Returns the configured tab keybinding family, or auto when unset/invalid.
      def composer_tab_keybindings(config = read_config)
        composer = config["composer"].is_a?(Hash) ? config["composer"] : {}
        value = composer["tab_keybindings"].to_s.downcase
        %w[auto ctrl alt].include?(value) ? value : "auto"
      end

      # Returns the built-in TUI editor keymap mode.
      def editor_mode(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        EditorMode.normalize(editor["mode"])
      end

      # Returns configured editor runner definitions, or an empty map.
      #
      # Runner defaults are resolved by the editor runner at execution time so
      # the generated config remains portable across machines.
      def editor_runners(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        runners = editor["runners"]
        runners.is_a?(Hash) ? runners : {}
      end

      # Returns the optional provider override for editor-agent turns.
      def editor_agent_provider(config = read_config)
        value = ENV["KWARD_EDITOR_PROVIDER"].to_s.strip
        return value unless value.empty?

        editor_agent_setting(config, "provider")
      end

      # Returns the optional model override for editor-agent turns.
      def editor_agent_model(config = read_config)
        editor_agent_setting(config, "model")
      end

      # Returns the optional reasoning-effort override for editor-agent turns.
      def editor_agent_reasoning_effort(config = read_config)
        editor_agent_setting(config, "reasoning_effort")
      end

      # Returns the shell-agent provider override, preferring the environment.
      def shell_agent_provider(config = read_config)
        value = ENV["KWSH_PROVIDER"].to_s.strip
        return value unless value.empty?

        shell_agent_setting(config, "provider")
      end

      # Returns the shell-agent model override, preferring the environment.
      def shell_agent_model(config = read_config)
        value = ENV["KWSH_MODE"].to_s.strip
        return value unless value.empty?

        shell_agent_setting(config, "model")
      end

      # Returns the shell-agent reasoning-effort override, preferring the environment.
      def shell_agent_reasoning_effort(config = read_config)
        value = ENV["KWSH_REASONING"].to_s.strip
        return value unless value.empty?

        shell_agent_setting(config, "reasoning_effort")
      end

      def editor_agent_setting(config, key)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        agent = editor["agent"].is_a?(Hash) ? editor["agent"] : {}
        value = agent[key].to_s.strip
        value.empty? ? nil : value
      end

      def shell_agent_setting(config, key)
        shell = config["shell"].is_a?(Hash) ? config["shell"] : {}
        agent = shell["agent"].is_a?(Hash) ? shell["agent"] : {}
        value = agent[key].to_s.strip
        value.empty? ? nil : value
      end

      # Returns whether the built-in TUI editor should auto-indent new lines.
      def editor_auto_indent?(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        editor["auto_indent"] != false
      end

      # Returns whether the built-in TUI editor should auto-close typed pairs.
      def editor_auto_close_pairs?(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        editor["auto_close_pairs"] != false
      end

      # Returns whether the built-in TUI editor should soft-wrap long lines.
      def editor_soft_wrap?(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        editor["soft_wrap"] != false
      end

      # Returns whether editable built-in TUI editor buffers should use a bar cursor.
      def editor_bar_cursor?(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        editor["bar_cursor"] != false
      end

      # Returns the built-in TUI editor line-number display mode.
      def editor_line_numbers(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        EditorMode.normalize_line_numbers(editor["line_numbers"])
      end

      # Returns the integrated diff viewer display mode.
      def diff_view(config = read_config)
        editor = config["editor"].is_a?(Hash) ? config["editor"] : {}
        DiffViewMode.normalize(editor["diff_view"])
      end

      # Returns whether file tools must stay inside the active workspace root.
      def workspace_guardrails_enabled?(config = read_config)
        tools = config["tools"].is_a?(Hash) ? config["tools"] : {}
        tools["workspace_guardrails"] != false
      end

      # Builds the opt-in model-tool permission policy from persisted configuration.
      def permission_policy(config = read_config)
        Permissions::Policy.from_config(config)
      end

      # Builds the user-controlled command sandbox policy for a workspace.
      def sandbox_policy(workspace_root, config = read_config)
        sandbox = config["sandbox"].is_a?(Hash) ? config["sandbox"] : {}
        Sandbox::Policy.new(
          mode: sandbox.fetch("mode", "off"),
          network: sandbox.fetch("network", "deny"),
          workspace_root: workspace_root,
          writable_roots: sandbox.fetch("writable_roots", []),
          protect_git_metadata: sandbox.fetch("protect_git_metadata", true)
        )
      end

      # Returns whether project-level Agent Skills should be loaded from the workspace.
      def project_skills_trusted?(config = read_config)
        skills = config["skills"].is_a?(Hash) ? config["skills"] : {}
        skills["trust_project"] == true
      end

      # Returns whether new frontends should resume the last active session automatically.
      def session_auto_resume_enabled?(config = read_config)
        sessions = config["sessions"].is_a?(Hash) ? config["sessions"] : {}
        sessions["auto_resume"] == true
      end

      # Returns whether workspace AGENTS.md contents should be injected directly
      # instead of a compact read-when-relevant instruction.
      def enforce_workspace_agents_file?(config = read_config)
        config["enforce_workspace_agents_file"] == true
      end

      # Returns the nested web-search config object, or an empty config when absent.
      def web_search_config(config = read_config)
        value = config["web_search"]
        value.is_a?(Hash) ? value : {}
      end

      # Returns the private configuration namespace for one transport.
      def transport_config(transport_id, config = read_config)
        transports = config["transports"]
        return {} unless transports.is_a?(Hash)

        values = transports[transport_id.to_s]
        values.is_a?(Hash) ? DeepCopy.dup(values) : {}
      end

      # Returns configured MCP stdio servers, or an empty config when absent.
      def mcp_servers(config = read_config)
        value = config["mcpServers"] || config.dig("mcp", "servers")
        value.is_a?(Hash) ? value : {}
      end

      # Validates and persists terminal overlay settings.
      def update_overlay_settings(values)
        raise "Overlay settings must be an object" unless values.is_a?(Hash)

        config = read_config
        overlay = overlay_settings(config)
        values.each do |key, value|
          key = key.to_s
          value = value.to_s
          case key
          when "alignment"
            raise "Overlay alignment must be left, center, or right" unless OVERLAY_ALIGNMENTS.include?(value)
          when "width"
            raise "Overlay width must be capped or maximum" unless OVERLAY_WIDTHS.include?(value)
          else
            raise "Unknown overlay setting: #{key}"
          end
          overlay[key] = value
        end
        config["overlay"] = overlay
        write_config(config)
        overlay_settings(config)
      end

      # Reads global principle instructions from the config directory.
      #
      # `PRINCIPLES.md` is preferred. `AGENTS.md` remains a backwards-compatible
      # alias for existing installations.
      #
      # @return [String, nil] prompt text, or nil when absent/too large
    end
  end
end
