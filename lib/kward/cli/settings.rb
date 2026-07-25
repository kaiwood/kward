# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive settings menu actions mixed into the CLI frontend.
    module Settings
      private

      def configure_settings(conversation = nil)
        unless settings_overlay_available?
          runtime_output("Settings overlay is unavailable in this prompt.")
          return
        end

        initial_index = 0
        loop do
          choices = settings_category_choices
          selected, selected_index = select_settings_menu_item("Settings category", choices, initial_index)
          category = selected_settings_category(selected)
          break unless category

          initial_index = selected_index if selected_index
          break if category == "done"

          handle_settings_category(category, conversation)
        end
      rescue StandardError => e
        runtime_output("Settings error: #{e.message}")
      end

      # Returns the category labels shown by the interactive settings overlay.
      def settings_category_choices
        [
          "Model & Reasoning",
          "Accounts",
          "Memory",
          "Interface",
          "Tools & Search",
          "Context & Compaction",
          "Personalization",
          "Logging",
          "Advanced",
          "Done"
        ]
      end

      # Maps a selected settings label back to the internal category key.
      def selected_settings_category(selected)
        text = selected.to_s.downcase
        return nil if text.empty?
        return "done" if text.start_with?("done")
        return "model" if text.start_with?("model")
        return "accounts" if text.start_with?("accounts")
        return "memory" if text.start_with?("memory")
        return "interface" if text.start_with?("interface")
        return "tools" if text.start_with?("tools")
        return "context" if text.start_with?("context")
        return "personalization" if text.start_with?("personalization")
        return "logging" if text.start_with?("logging")
        return "advanced" if text.start_with?("advanced")

        nil
      end

      def handle_settings_category(category, conversation)
        case category
        when "model"
          configure_model_settings(conversation)
        when "accounts"
          configure_account_settings
        when "memory"
          configure_memory_settings(conversation)
        when "interface"
          configure_interface_settings
        when "tools"
          configure_tools_settings
        when "context"
          configure_context_settings
        when "personalization"
          configure_personalization_settings(conversation)
        when "logging"
          configure_logging_settings
        when "advanced"
          show_advanced_settings
        end
      end

      def configure_model_settings(conversation)
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Model & Reasoning", ["Provider", "Default model", "Local server preset", "Reasoning effort", "Back"], initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Aprovider/
            configure_provider(conversation)
          when /\Adefault model/
            configure_model(conversation)
          when /\Alocal server preset/
            configure_local_server_preset(conversation)
          when /\Areasoning effort/
            configure_reasoning(conversation)
          else
            break
          end
        end
      end

      def configure_provider(conversation)
        selected = @prompt.select("Provider", provider_choices, title: "Settings")
        provider = selected_provider(selected)
        return unless provider

        ConfigFiles.update_config("provider" => ModelInfo.config_provider_for_provider(provider))
        reload_client_config
        refresh_conversation_runtime(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw)
      end

      def provider_choices
        current = current_model_provider
        ["Codex", "Anthropic", "OpenRouter", "Copilot", "Local"].map do |provider|
          label = provider.dup
          label += " (current)" if provider == current
          label
        end
      end

      def selected_provider(selected)
        text = selected.to_s.downcase
        return "Codex" if text.start_with?("codex")
        return "Anthropic" if text.start_with?("anthropic") || text.start_with?("claude")
        return "OpenRouter" if text.start_with?("openrouter")
        return "Copilot" if text.start_with?("copilot")
        return "Local" if text.start_with?("local")

        nil
      end

      def configure_local_server_preset(conversation)
        choices = [
          "Ollama (http://127.0.0.1:11434/v1)",
          "LM Studio (http://127.0.0.1:1234/v1)",
          "llama.cpp (http://127.0.0.1:8080/v1)",
          "Custom endpoint (edit config)",
          "Back"
        ]
        selected = @prompt.select("Local server preset", choices, title: "Settings")
        return unless selected

        backend, url = case selected.to_s
                       when /\AOllama/ then ["ollama", "http://127.0.0.1:11434/v1"]
                       when /\ALM Studio/ then ["lm_studio", "http://127.0.0.1:1234/v1"]
                       when /\Allama\.cpp/ then ["llama_cpp", "http://127.0.0.1:8080/v1"]
                       when /\ACustom endpoint/
                         runtime_output("Set local_base_url in #{ConfigFiles.config_path}.")
                         return
                       else
                         return
                       end

        ConfigFiles.update_config("local_backend" => backend, "local_base_url" => url)
        reload_client_config
        refresh_conversation_runtime(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw)
      end

      def configure_account_settings
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Accounts", account_setting_choices, initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Aopenai/
            login(provider: "openai")
            reload_client_config
          when /\Aanthropic/, /\Aclaude/
            login(provider: "anthropic")
            reload_client_config
          when /\Agithub/
            login(provider: "github")
            reload_client_config
          when /\Aopenrouter/
            login(provider: "openrouter")
            reload_client_config
          when /\Astatus/
            print_auth_status
          else
            break
          end
        end
      end

      def account_setting_choices
        config = safely_read_config.to_h
        [
          "OpenAI login (#{File.exist?(OpenAIOAuth.default_auth_path) ? "configured" : "not configured"})",
          "Anthropic login (#{File.exist?(AnthropicOAuth.default_auth_path) ? "configured" : "not configured"})",
          "GitHub login (#{File.exist?(GithubOAuth.default_auth_path) ? "configured" : "not configured"})",
          "OpenRouter API key (#{openrouter_key_status(config)})",
          "Status",
          "Back"
        ]
      end

      def openrouter_key_status(config)
        return "configured via environment" unless ENV["OPENROUTER_API_KEY"].to_s.empty?

        config["openrouter_api_key"].to_s.empty? ? "not configured" : "configured"
      end

      def configure_memory_settings(conversation)
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Memory", memory_setting_choices, initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Aenable memory/, /\Adisable memory/
            set_config_flag("memory", "enabled", !memory_enabled?)
            conversation&.refresh_system_message!
            runtime_output("Memory #{memory_enabled? ? "enabled" : "disabled"}.")
          when /\Aenable auto-summary/, /\Adisable auto-summary/
            set_config_flag("memory", "auto_summary", !memory_auto_summary_enabled?)
            runtime_output("Memory auto-summary #{memory_auto_summary_enabled? ? "enabled" : "disabled"}.")
          when /\Amanage/
            runtime_output("Use /memory enable|disable|auto-summary enable|disable|core <text>|add <text>|list|forget <id>|promote <id>|relax <id>|inspect|why|summarize.")
          else
            break
          end
        end
      end

      def memory_setting_choices
        [
          "#{memory_enabled? ? "Disable" : "Enable"} memory (currently #{on_off(memory_enabled?)})",
          "#{memory_auto_summary_enabled? ? "Disable" : "Enable"} auto-summary (currently #{on_off(memory_auto_summary_enabled?)})",
          "Manage memories with /memory",
          "Back"
        ]
      end

      def memory_enabled?
        memory = safely_read_config.to_h["memory"]
        memory.is_a?(Hash) && memory["enabled"] == true
      end

      def memory_auto_summary_enabled?
        memory = safely_read_config.to_h["memory"]
        memory.is_a?(Hash) && memory["auto_summary"] == true
      end

      def configure_interface_settings
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Interface", interface_setting_choices, initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Aoverlay alignment/
            settings = ConfigFiles.overlay_settings
            alignment = choose_overlay_setting("Overlay alignment", overlay_alignment_choices(settings), ConfigFiles::OVERLAY_ALIGNMENTS)
            next unless alignment

            update_overlay_settings("alignment" => alignment)
          when /\Aoverlay width/
            settings = ConfigFiles.overlay_settings
            width = choose_overlay_setting("Overlay width", overlay_width_choices(settings), ConfigFiles::OVERLAY_WIDTHS)
            next unless width

            update_overlay_settings("width" => width)
          when /\Afile icons/
            configure_project_browser_icon_theme
          when /\Ashow busy help/, /\Ahide busy help/
            set_composer_busy_help(!composer_busy_help?)
            runtime_output("Busy help #{composer_busy_help? ? "enabled" : "disabled"}. Restart the TUI to apply this setting.")
          when /\Atab keybindings/
            configure_tab_keybindings
          when /\Aeditor mode/
            configure_editor_mode
          when /\Aeditor line numbers/
            configure_editor_line_numbers
          when /\Adiff view/
            configure_diff_view
          when /\Aenable auto-close pairs/, /\Adisable auto-close pairs/
            set_config_flag("editor", "auto_close_pairs", !editor_auto_close_pairs_enabled?)
            runtime_output("Editor auto-close pairs #{editor_auto_close_pairs_enabled? ? "enabled" : "disabled"}.")
          when /\Aenable soft-wrap/, /\Adisable soft-wrap/
            set_config_flag("editor", "soft_wrap", !editor_soft_wrap_enabled?)
            runtime_output("Editor soft-wrap #{editor_soft_wrap_enabled? ? "enabled" : "disabled"}.")
          when /\Aenable bar cursor/, /\Adisable bar cursor/
            set_config_flag("editor", "bar_cursor", !editor_bar_cursor_enabled?)
            runtime_output("Editor bar cursor #{editor_bar_cursor_enabled? ? "enabled" : "disabled"}.")
          when /\Aenable session auto-resume/, /\Adisable session auto-resume/
            set_config_flag("sessions", "auto_resume", !session_auto_resume_enabled?)
            runtime_output("Session auto-resume #{session_auto_resume_enabled? ? "enabled" : "disabled"}.")
          else
            break
          end
        end
      end

      def interface_setting_choices
        settings = ConfigFiles.overlay_settings
        [
          "Overlay alignment (#{settings["alignment"]})",
          "Overlay width (#{settings["width"]})",
          "File icons (#{project_browser_icon_theme})",
          "#{composer_busy_help? ? "Hide" : "Show"} busy help (currently #{on_off(composer_busy_help?)})",
          "Tab keybindings (#{composer_tab_keybindings})",
          "Editor mode (#{editor_mode})",
          "Editor line numbers (#{editor_line_numbers})",
          "Diff view (#{diff_view_label(diff_view)})",
          "#{editor_auto_close_pairs_enabled? ? "Disable" : "Enable"} auto-close pairs (currently #{on_off(editor_auto_close_pairs_enabled?)})",
          "#{editor_soft_wrap_enabled? ? "Disable" : "Enable"} soft-wrap (currently #{on_off(editor_soft_wrap_enabled?)})",
          "#{editor_bar_cursor_enabled? ? "Disable" : "Enable"} bar cursor (currently #{on_off(editor_bar_cursor_enabled?)})",
          "#{session_auto_resume_enabled? ? "Disable" : "Enable"} session auto-resume (currently #{on_off(session_auto_resume_enabled?)})",
          "Back"
        ]
      end

      def project_browser_icon_theme
        ConfigFiles.project_browser_icon_theme(safely_read_config.to_h)
      end

      def configure_project_browser_icon_theme
        selected = @prompt.select("File icons", project_browser_icon_theme_choices, title: "Settings")
        theme = selected.to_s.split.first.to_s.downcase
        return unless ConfigFiles::PROJECT_BROWSER_ICON_THEMES.include?(theme)

        update_nested_config("project_browser", "icons" => theme)
        @prompt.update_project_browser_icon_theme(theme) if @prompt.respond_to?(:update_project_browser_icon_theme)
        runtime_output("File icons set to #{theme}.")
      end

      def project_browser_icon_theme_choices
        current = project_browser_icon_theme
        ConfigFiles::PROJECT_BROWSER_ICON_THEMES.map { |theme| theme == current ? "#{theme} (current)" : theme }
      end

      def composer_busy_help?
        ConfigFiles.composer_busy_help?(safely_read_config.to_h)
      end

      def composer_tab_keybindings
        ConfigFiles.composer_tab_keybindings(safely_read_config.to_h)
      end

      def configure_tab_keybindings
        selected = @prompt.select("Tab keybindings", tab_keybinding_choices, title: "Settings")
        value = selected.to_s.split.first.to_s.downcase
        return unless %w[auto ctrl alt].include?(value)

        update_nested_config("composer", "tab_keybindings" => value)
        runtime_output("Tab keybindings set to #{value}. Restart the TUI to apply this setting.")
      end

      def tab_keybinding_choices
        current = composer_tab_keybindings
        %w[auto ctrl alt].map { |value| value == current ? "#{value} (current)" : value }
      end

      def editor_mode
        ConfigFiles.editor_mode(safely_read_config.to_h)
      end

      def configure_editor_mode
        selected = @prompt.select("Editor mode", editor_mode_choices, title: "Settings")
        value = selected.to_s.split.first.to_s.downcase
        return unless %w[modern emacs vibe].include?(value)

        update_nested_config("editor", "mode" => value)
        runtime_output("Editor mode set to #{value}. New editor buffers will use this mode.")
      end

      def editor_mode_choices
        current = editor_mode
        %w[modern emacs vibe].map { |value| value == current ? "#{value} (current)" : value }
      end

      def editor_line_numbers
        ConfigFiles.editor_line_numbers(safely_read_config.to_h)
      end

      def configure_editor_line_numbers
        selected = @prompt.select("Editor line numbers", editor_line_number_choices, title: "Settings")
        value = selected.to_s.split.first.to_s.downcase
        return unless %w[absolute relative].include?(value)

        update_nested_config("editor", "line_numbers" => value)
        runtime_output("Editor line numbers set to #{value}.")
      end

      def editor_line_number_choices
        current = editor_line_numbers
        %w[absolute relative].map { |value| value == current ? "#{value} (current)" : value }
      end

      def diff_view
        ConfigFiles.diff_view(safely_read_config.to_h)
      end

      def configure_diff_view
        selected = @prompt.select("Diff view", diff_view_choices, title: "Settings")
        value = selected.to_s.split.first.to_s.downcase.tr("-", "_")
        return unless Kward::DiffViewMode::MODES.include?(value)

        update_nested_config("editor", "diff_view" => value)
        runtime_output("Diff view set to #{diff_view_label(value)}.")
      end

      def diff_view_choices
        current = diff_view
        Kward::DiffViewMode::MODES.map do |value|
          label = diff_view_label(value)
          value == current ? "#{label} (current)" : label
        end
      end

      def diff_view_label(value)
        Kward::DiffViewMode.label(value)
      end

      def editor_auto_close_pairs_enabled?
        ConfigFiles.editor_auto_close_pairs?(safely_read_config.to_h)
      end

      def editor_soft_wrap_enabled?
        ConfigFiles.editor_soft_wrap?(safely_read_config.to_h)
      end

      def editor_bar_cursor_enabled?
        ConfigFiles.editor_bar_cursor?(safely_read_config.to_h)
      end

      def session_auto_resume_enabled?
        ConfigFiles.session_auto_resume_enabled?(safely_read_config.to_h)
      end

      def set_composer_busy_help(enabled)
        set_config_flag("composer", "busy_help", enabled)
      end

      def configure_tools_settings
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Tools & Search", tools_setting_choices, initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Aenable web search/, /\Adisable web search/
            set_config_flag("web_search", "enabled", !web_search_enabled?)
            runtime_output("Web search #{web_search_enabled? ? "enabled" : "disabled"}.")
          when /\Aweb search provider/
            configure_web_search_provider
          when /\Aallow model-provider/, /\Adisallow model-provider/
            set_config_flag("web_search", "allow_model_providers", !web_search_allow_model_providers?)
            runtime_output("Model-provider web search #{web_search_allow_model_providers? ? "enabled" : "disabled"}.")
          when /\Atrust project skills/, /\Auntrust project skills/
            set_config_flag("skills", "trust_project", !project_skills_trusted?)
            runtime_output("Project skills #{project_skills_trusted? ? "trusted" : "untrusted"}.")
          when /\Aenable workspace guardrails/, /\Adisable workspace guardrails/
            set_config_flag("tools", "workspace_guardrails", !workspace_guardrails_enabled?)
            runtime_output("Workspace guardrails #{workspace_guardrails_enabled? ? "enabled" : "disabled"}.")
          else
            break
          end
        end
      end

      def tools_setting_choices
        [
          "#{web_search_enabled? ? "Disable" : "Enable"} web search (currently #{on_off(web_search_enabled?)})",
          "Web search provider (#{web_search_provider})",
          "#{web_search_allow_model_providers? ? "Disallow" : "Allow"} model-provider web search (currently #{on_off(web_search_allow_model_providers?)})",
          "#{project_skills_trusted? ? "Untrust" : "Trust"} project skills (currently #{on_off(project_skills_trusted?)})",
          "#{workspace_guardrails_enabled? ? "Disable" : "Enable"} workspace guardrails (currently #{on_off(workspace_guardrails_enabled?)})",
          "Back"
        ]
      end

      def configure_web_search_provider
        providers = WebSearch::PROVIDERS
        selected = @prompt.select("Web search provider", providers.map { |provider| provider == web_search_provider ? "#{provider} (current)" : provider }, title: "Settings")
        provider = providers.find { |value| selected.to_s.downcase.start_with?(value) }
        return unless provider

        update_nested_config("web_search", "provider" => provider)
      end

      def web_search_config
        ConfigFiles.web_search_config(safely_read_config.to_h)
      end

      def web_search_enabled?
        web_search_config["enabled"] != false
      end

      def web_search_provider
        web_search_config["provider"].to_s.empty? ? "auto" : web_search_config["provider"].to_s
      end

      def web_search_allow_model_providers?
        web_search_config["allow_model_providers"] == true
      end

      def project_skills_trusted?
        ConfigFiles.project_skills_trusted?(safely_read_config.to_h)
      end

      def configure_context_settings
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Context & Compaction", context_setting_choices, initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Aenable auto-compaction/, /\Adisable auto-compaction/
            set_config_flag("compaction", "enabled", !compaction_enabled?)
            runtime_output("Auto-compaction #{compaction_enabled? ? "enabled" : "disabled"}.")
          when /\Astatus/
            runtime_output(auto_compaction_status_line)
          else
            break
          end
        end
      end

      def context_setting_choices
        [
          "#{compaction_enabled? ? "Disable" : "Enable"} auto-compaction (currently #{on_off(compaction_enabled?)})",
          "Status",
          "Back"
        ]
      end

      def compaction_enabled?
        Kward::Compaction::Settings.from_config(safely_read_config.to_h).enabled
      end

      def configure_personalization_settings(conversation)
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Personalization", personalization_setting_choices(conversation), initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          case selected.to_s.downcase
          when /\Adefault persona/
            configure_default_persona(conversation)
          when /\Aenable global principles/, /\Adisable global principles/
            toggle_global_principles(conversation)
          when /\Aglobal principles \(ignored/
            runtime_output("Global principles are ignored while a replacement system prompt is configured.")
          when /\Aactive instructions/
            show_active_instructions_summary(conversation)
          else
            break
          end
        end
      end

      def personalization_setting_choices(conversation)
        config = safely_read_config.to_h
        replacement = ConfigFiles.system_prompt_file_path(config)
        principles = if replacement
                       "Global principles (ignored by replacement)"
                     elsif ConfigFiles.include_config_principles?(config)
                       "Disable global principles"
                     else
                       "Enable global principles"
                     end
        [
          "Default persona (#{default_persona_label})",
          principles,
          "Active instructions summary",
          "Back"
        ]
      end

      def toggle_global_principles(conversation)
        config = safely_read_config.to_h
        settings = config["system_prompt"].is_a?(Hash) ? config["system_prompt"] : {}
        ConfigFiles.update_config("system_prompt" => settings.merge("include_principles" => !ConfigFiles.include_config_principles?(config)))
        conversation&.refresh_system_message!
        @prompt.redraw if @prompt.respond_to?(:redraw)
      end

      def default_persona_label
        personas = safely_read_config.to_h["personas"]
        value = personas.is_a?(Hash) ? personas["default"] : nil
        value.to_s.empty? ? "none" : value.to_s
      end

      def configure_default_persona(conversation)
        config = safely_read_config.to_h
        personas = config["personas"].is_a?(Hash) ? config["personas"] : {}
        entries = ConfigFiles.crew_character_labels(personas)
        choices = entries.map { |key, label| key == personas["default"] ? "#{label} (#{key}, current)" : "#{label} (#{key})" }
        if choices.empty?
          runtime_output("No configured personas found. Edit #{ConfigFiles.config_path} to add personas.")
          return
        end

        selected = @prompt.select("Default persona", choices, title: "Settings")
        key = entries.keys.find { |candidate| selected.to_s.include?("(#{candidate}") }
        return unless key

        personas = personas.dup
        personas["default"] = key
        ConfigFiles.update_config("personas" => personas)
        conversation&.refresh_system_message!
        @prompt.redraw if @prompt.respond_to?(:redraw)
      end

      def show_active_instructions_summary(conversation)
        label = ConfigFiles.active_persona_label(workspace_root: current_workspace_root, model: current_model_id, config: safely_read_config.to_h)
        config = safely_read_config.to_h
        replacement_path = ConfigFiles.system_prompt_file_path(config)
        lines = ["Active persona: #{label || "none"}"]
        if replacement_path
          lines << "System prompt: replacement (#{replacement_path})"
          lines << "Global PRINCIPLES.md: ignored by replacement"
          lines << "Workspace AGENTS.md: ignored by replacement"
        else
          lines << "System prompt: Kward default"
          lines << "Global PRINCIPLES.md: #{ConfigFiles.include_config_principles?(config) ? (ConfigFiles.agents_prompt ? "present" : "absent") : "disabled"}"
          lines << "Workspace AGENTS.md: #{ConfigFiles.workspace_agents_prompt(current_workspace_root) ? "present" : "absent"}"
        end
        lines << "Messages: #{conversation.messages.length}" if conversation&.respond_to?(:messages)
        runtime_output(lines.join("\n"))
      end

      def configure_logging_settings
        initial_index = 0
        loop do
          selected, selected_index = select_settings_menu_item("Logging", logging_setting_choices, initial_index)
          break unless selected

          initial_index = selected_index if selected_index
          key = logging_key_for_choice(selected)
          break unless key

          set_logging_value(key, !logging_enabled?(key))
          runtime_output("Logging #{key.tr("_", " ")} #{logging_enabled?(key) ? "enabled" : "disabled"}.")
        end
      end

      def logging_setting_choices
        [
          "#{logging_enabled?("enabled") ? "Disable" : "Enable"} local logging (currently #{on_off(logging_enabled?("enabled"))})",
          "#{logging_enabled?("tokens") ? "Disable" : "Enable"} token logs (currently #{on_off(logging_enabled?("tokens"))})",
          "#{logging_enabled?("performance") ? "Disable" : "Enable"} performance logs (currently #{on_off(logging_enabled?("performance"))})",
          "#{logging_enabled?("tools") ? "Disable" : "Enable"} tool logs (currently #{on_off(logging_enabled?("tools"))})",
          "#{logging_enabled?("errors") ? "Disable" : "Enable"} error logs (currently #{on_off(logging_enabled?("errors"))})",
          "Back"
        ]
      end

      def logging_key_for_choice(selected)
        text = selected.to_s.downcase
        return "enabled" if text.include?("local logging")
        return "tokens" if text.include?("token logs")
        return "performance" if text.include?("performance logs")
        return "tools" if text.include?("tool logs")
        return "errors" if text.include?("error logs")

        nil
      end

      def logging_enabled?(key)
        logging = safely_read_config.to_h["logging"]
        logging.is_a?(Hash) && logging[key] == true
      end

      def set_logging_value(key, value)
        set_config_flag("logging", key, value)
      end

      def show_advanced_settings
        lines = [
          "Config path: #{ConfigFiles.config_path}",
          "Config directory: #{ConfigFiles.config_dir}",
          "Cache directory: #{ConfigFiles.cache_dir}",
          "Memory directory: #{ConfigFiles.memory_dir}",
          "Plugin directory: #{ConfigFiles.plugin_dir}",
          "Plugins: #{ConfigFiles.plugin_paths.length}",
          "Skills: #{ConfigFiles.skills.length}",
          "Prompt templates: #{ConfigFiles.prompt_templates(reserved_commands: BUILTIN_SLASH_COMMAND_NAMES).length}"
        ]
        runtime_output(lines.join("\n"))
      end

      def update_nested_config(section, values)
        ConfigFiles.update_nested_config(section, values)
      end

      def set_config_flag(section, key, enabled)
        update_nested_config(section, key => enabled)
      end

      def select_settings_menu_item(message, choices, initial_index)
        selected = @prompt.select(message, choices, title: "Settings", initial_index: initial_index)
        [selected, choices.index(selected)]
      end

      def on_off(value)
        value ? "on" : "off"
      end

      def login_interactively
        unless login_picker_available?
          runtime_output("Login provider picker is unavailable in this prompt.")
          return
        end

        method = selected_login_method(@prompt.select("How would you like to connect?", login_method_choices, title: "Login"))
        return unless method

        selected = @prompt.select(login_provider_prompt(method), login_provider_choices(method), title: "Login")
        provider = selected_login_provider(selected)
        return unless provider

        run_busy_local_command_and_requeue(activity: "running") do
          login(provider: provider, auth_method: method)
          reload_client_config
        end
      rescue StandardError => e
        runtime_output("Login error: #{e.message}")
      end

      def configure_model(conversation = nil, models: nil)
        unless model_overlay_available?
          runtime_output("Model overlay is unavailable in this prompt.")
          return
        end

        models ||= normalized_available_models(conversation)
        choices = model_choices(models, conversation)
        selected = @prompt.select("Default model", choices, title: "Models", custom: true)
        return unless selected

        provider, model = selected_model(selected, models)
        raise "Model must be a non-empty string" if model.to_s.strip.empty?

        ConfigFiles.update_config(ModelInfo.config_values_for_selection(provider, model))
        reload_client_config
        refresh_conversation_runtime(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw)
      rescue StandardError => e
        runtime_output("Model error: #{e.message}")
      end

      def configure_reasoning(conversation = nil)
        unless model_overlay_available?
          runtime_output("Reasoning overlay is unavailable in this prompt.")
          return
        end

        provider = conversation&.provider || current_model_provider
        model = conversation&.model || current_model_id
        choices = ModelInfo.reasoning_effort_choices(provider, model)
        if choices.empty?
          runtime_output("Reasoning effort is unavailable for #{provider} #{model}.")
          return
        end

        selected = @prompt.select("Reasoning effort", reasoning_choices(choices, conversation), title: "Reasoning")
        return unless selected

        effort, = choices.find { |_value, label| selected.to_s.downcase.start_with?(label.downcase) }
        raise "Reasoning effort must be one of: #{choices.map(&:first).join(", ")}" unless effort

        set_reasoning_effort(effort, conversation, provider: provider)
      rescue StandardError => e
        runtime_output("Reasoning error: #{e.message}")
      end

      def login_picker_available?
        @prompt.respond_to?(:select)
      end

      def login_method_choices
        ["API key", "Subscription / OAuth"]
      end

      def selected_login_method(selected)
        case selected.to_s.downcase
        when /\Aapi key\z/ then :api_key
        when /\Asubscription \/ oauth\z/ then :oauth
        end
      end

      def login_provider_prompt(method)
        method == :api_key ? "Add an API key" : "Sign in with a subscription"
      end

      def login_provider_choices(method)
        if method == :api_key
          ProviderCatalog.api_key_providers.map(&:name)
        else
          ["Anthropic Claude", "ChatGPT", "GitHub Copilot"]
        end
      end

      def selected_login_provider(selected)
        value = selected.to_s.downcase
        return "openai" if value == "openai" || value == "chatgpt"
        return "anthropic" if value == "anthropic" || value == "anthropic claude"
        return "copilot" if value == "github copilot"

        ProviderCatalog.find_by_name(selected)&.id
      end

      def model_overlay_available?
        @prompt.respond_to?(:select)
      end

      def settings_overlay_available?
        @prompt.respond_to?(:select)
      end

      def update_overlay_settings(values)
        settings = ConfigFiles.update_overlay_settings(values)
        @prompt.update_overlay_settings(settings) if @prompt.respond_to?(:update_overlay_settings)
        settings
      end

      def choose_overlay_setting(message, choices, values)
        choice = @prompt.select(message, choices, title: "Settings")
        return nil unless choice

        values.find { |value| choice.to_s.downcase.start_with?(value) }
      end

      def normalized_available_models(conversation = current_footer_conversation)
        current_provider = conversation.provider || (@client.respond_to?(:current_provider) ? @client.current_provider : "Codex")
        current_model = conversation.model || (@client.respond_to?(:current_model) ? @client.current_model : nil)
        current_reasoning = conversation.reasoning_effort || (@client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : nil)
        models = @client.respond_to?(:available_models) ? @client.available_models : []
        ModelInfo.normalize_available(
          models,
          current_provider: current_provider,
          current_model: current_model,
          current_reasoning_effort: current_reasoning
        )
      end

      def model_choices(models, conversation = current_footer_conversation)
        current_provider = conversation.provider || current_model_provider
        current_model = conversation.model || current_model_id
        choices = models.map do |model|
          label = "#{model[:provider]} #{model[:id]}"
          label += " (current)" if model[:current]
          label
        end
        choices.empty? ? ["#{current_provider} #{current_model} (current)"] : choices.uniq
      end

      def selected_model(selected, models)
        text = selected.to_s.sub(/ \(current\)\z/, "").strip
        known = models.find { |model| "#{model[:provider]} #{model[:id]}" == text }
        return [known[:provider], known[:id]] if known

        provider, model = text.split(/\s+/, 2)
        if ["Codex", "Anthropic", "OpenRouter", "Copilot"].include?(provider) && !model.to_s.strip.empty?
          [provider, model.strip]
        else
          [current_model_provider, text]
        end
      end

      REASONING_CONFIG_DEBOUNCE_SECONDS = 0.5

      def cycle_reasoning(conversation = current_footer_conversation, direction: :next, persist: :immediate)
        provider = conversation&.provider || current_model_provider
        model = conversation&.model || current_model_id
        choices = ModelInfo.reasoning_effort_choices(provider, model)
        return false if choices.empty?

        current = (pending_reasoning_effort(provider) || conversation&.reasoning_effort || current_reasoning_effort).to_s
        current_index = choices.index { |effort, _label| effort == current }
        current_index ||= direction == :previous ? 0 : -1
        offset = direction == :previous ? -1 : 1
        effort = choices[(current_index + offset) % choices.length].first
        persist == :debounced ? apply_reasoning_effort(effort, conversation, provider: provider) : set_reasoning_effort(effort, conversation, provider: provider)
        true
      rescue StandardError => e
        runtime_output("Reasoning error: #{e.message}")
        false
      end

      def set_reasoning_effort(effort, conversation = nil, provider: nil)
        @pending_reasoning_config_mutex.synchronize { @pending_reasoning_config = nil }
        persist_reasoning_config(effort, provider: provider)
        apply_reasoning_effort(effort, conversation, provider: provider, queue_config: false)
      end

      def apply_reasoning_effort(effort, conversation = nil, provider: nil, queue_config: true)
        queue_reasoning_config(effort, provider: provider, conversation: conversation) if queue_config
        if queue_config
          update_conversation_reasoning_effort(conversation, effort)
          refresh_reasoning_status
        else
          refresh_conversation_runtime(conversation, reasoning_effort: effort)
          @prompt.redraw if @prompt.respond_to?(:redraw)
        end
      end

      def refresh_reasoning_status
        if @prompt.respond_to?(:refresh_composer_status)
          @prompt.refresh_composer_status
        else
          @prompt.redraw if @prompt.respond_to?(:redraw)
        end
      end

      def update_conversation_reasoning_effort(conversation, effort)
        return unless conversation&.respond_to?(:update_runtime_context!)

        conversation.update_runtime_context!(
          provider: conversation.provider || current_model_provider,
          model: conversation.model || current_model_id,
          reasoning_effort: effort,
          refresh: false
        )
      end

      def pending_reasoning_effort(provider)
        @pending_reasoning_config_mutex.synchronize do
          pending = @pending_reasoning_config
          return nil unless pending
          return nil unless pending[:provider].to_s.downcase == provider.to_s.downcase

          pending[:effort]
        end
      end

      def queue_reasoning_config(effort, provider: nil, conversation: nil)
        pending = {
          effort: effort,
          provider: provider || current_model_provider,
          conversation: conversation,
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + REASONING_CONFIG_DEBOUNCE_SECONDS
        }
        @pending_reasoning_config_mutex.synchronize { @pending_reasoning_config = pending }
        schedule_reasoning_config_flush
      end

      def schedule_reasoning_config_flush
        return if @pending_reasoning_config_thread&.alive?

        @pending_reasoning_config_thread = Thread.new do
          loop do
            sleep REASONING_CONFIG_DEBOUNCE_SECONDS
            break if flush_pending_reasoning_config(force: false)
            break unless @pending_reasoning_config_mutex.synchronize { @pending_reasoning_config }
          end
        rescue StandardError => e
          runtime_output("Reasoning error: #{e.message}")
        end
      end

      def flush_pending_reasoning_config(force: true, conversation: nil)
        pending = nil
        @pending_reasoning_config_mutex.synchronize do
          pending = @pending_reasoning_config
          return false unless pending

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if !force && now < pending[:deadline].to_f

          @pending_reasoning_config = nil
        end
        persist_reasoning_config(pending[:effort], provider: pending[:provider])
        conversation ||= pending[:conversation]
        if conversation&.reasoning_effort.to_s == pending[:effort].to_s
          refresh_conversation_runtime(conversation, reasoning_effort: pending[:effort])
          conversation.persist_runtime_context! if conversation.respond_to?(:persist_runtime_context!)
        end
        true
      end

      def persist_reasoning_config(effort, provider: nil)
        ConfigFiles.update_config(ModelInfo.reasoning_config_key_for_provider(provider || current_model_provider) => effort)
        reload_client_config
      end

      def reasoning_choices(choices, conversation = current_footer_conversation)
        current = (conversation.reasoning_effort || (@client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : ModelInfo::DEFAULT_REASONING_EFFORT)).to_s
        choices.map do |effort, label|
          text = label.dup
          text += " (current)" if current == effort
          text
        end
      end

      def overlay_alignment_choices(settings)
        ConfigFiles::OVERLAY_ALIGNMENTS.map do |alignment|
          label = alignment.capitalize
          label += " (current)" if settings["alignment"] == alignment
          label
        end
      end

      def overlay_width_choices(settings)
        ConfigFiles::OVERLAY_WIDTHS.map do |width|
          label = width.capitalize
          label += " (current)" if settings["width"] == width
          label
        end
      end

    end
  end
end
