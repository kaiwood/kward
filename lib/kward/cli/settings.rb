# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Interactive settings menu actions mixed into the CLI frontend.
    module Settings
      private

      def configure_settings(conversation = nil)
        unless settings_overlay_available?
          @prompt.say("\nSettings overlay is unavailable in this prompt.\n")
          return
        end

        loop do
          selected = @prompt.select("Settings category", settings_category_choices, title: "Settings")
          category = selected_settings_category(selected)
          break unless category

          break if category == "done"

          handle_settings_category(category, conversation)
        end
      rescue StandardError => e
        @prompt.say("\nSettings error: #{e.message}\n")
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
        selected = @prompt.select("Model & Reasoning", ["Provider", "Default model", "Reasoning effort", "Back"], title: "Settings")
        case selected.to_s.downcase
        when /\Aprovider/
          configure_provider(conversation)
        when /\Adefault model/
          configure_model(conversation)
        when /\Areasoning effort/
          configure_reasoning(conversation)
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
        ["Codex", "Anthropic", "OpenRouter", "Copilot"].map do |provider|
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

        nil
      end

      def configure_account_settings
        selected = @prompt.select("Accounts", account_setting_choices, title: "Settings")
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
        selected = @prompt.select("Memory", memory_setting_choices, title: "Settings")
        case selected.to_s.downcase
        when /\Aenable memory/, /\Adisable memory/
          set_memory_enabled(!memory_enabled?)
          conversation&.refresh_system_message!
          @prompt.say("\nMemory #{memory_enabled? ? "enabled" : "disabled"}.\n")
        when /\Aenable auto-summary/, /\Adisable auto-summary/
          set_memory_auto_summary_enabled(!memory_auto_summary_enabled?)
          @prompt.say("\nMemory auto-summary #{memory_auto_summary_enabled? ? "enabled" : "disabled"}.\n")
        when /\Amanage/
          @prompt.say("\nUse /memory enable|disable|auto-summary enable|disable|core <text>|add <text>|list|forget <id>|promote <id>|relax <id>|inspect|why|summarize.\n")
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

      def set_memory_enabled(enabled)
        update_nested_config("memory", "enabled" => enabled)
      end

      def set_memory_auto_summary_enabled(enabled)
        update_nested_config("memory", "auto_summary" => enabled)
      end

      def configure_interface_settings
        selected = @prompt.select("Interface", interface_setting_choices, title: "Settings")
        case selected.to_s.downcase
        when /\Aoverlay alignment/
          settings = ConfigFiles.overlay_settings
          alignment = choose_overlay_setting("Overlay alignment", overlay_alignment_choices(settings), ConfigFiles::OVERLAY_ALIGNMENTS)
          return unless alignment

          @prompt.update_overlay_settings(ConfigFiles.update_overlay_settings("alignment" => alignment))
        when /\Aoverlay width/
          settings = ConfigFiles.overlay_settings
          width = choose_overlay_setting("Overlay width", overlay_width_choices(settings), ConfigFiles::OVERLAY_WIDTHS)
          return unless width

          @prompt.update_overlay_settings(ConfigFiles.update_overlay_settings("width" => width))
        when /\Ashow busy help/, /\Ahide busy help/
          set_composer_busy_help(!composer_busy_help?)
          @prompt.say("\nBusy help #{composer_busy_help? ? "enabled" : "disabled"}. Restart the TUI to apply this setting.\n")
        when /\Ashow startup banner/, /\Ahide startup banner/
          set_banner_enabled(!banner_enabled?)
          @prompt.say("\nStartup banner #{banner_enabled? ? "enabled" : "disabled"}. Restart the TUI to apply this setting.\n")
        when /\Aenable session auto-resume/, /\Adisable session auto-resume/
          set_session_auto_resume_enabled(!session_auto_resume_enabled?)
          @prompt.say("\nSession auto-resume #{session_auto_resume_enabled? ? "enabled" : "disabled"}.\n")
        end
      end

      def interface_setting_choices
        settings = ConfigFiles.overlay_settings
        [
          "Overlay alignment (#{settings["alignment"]})",
          "Overlay width (#{settings["width"]})",
          "#{composer_busy_help? ? "Hide" : "Show"} busy help (currently #{on_off(composer_busy_help?)})",
          "#{banner_enabled? ? "Hide" : "Show"} startup banner (currently #{on_off(banner_enabled?)})",
          "#{session_auto_resume_enabled? ? "Disable" : "Enable"} session auto-resume (currently #{on_off(session_auto_resume_enabled?)})",
          "Back"
        ]
      end

      def composer_busy_help?
        ConfigFiles.composer_busy_help?(safely_read_config.to_h)
      end

      def banner_enabled?
        ConfigFiles.banner_enabled?(safely_read_config.to_h)
      end

      def session_auto_resume_enabled?
        ConfigFiles.session_auto_resume_enabled?(safely_read_config.to_h)
      end

      def set_composer_busy_help(enabled)
        update_nested_config("composer", "busy_help" => enabled)
      end

      def set_banner_enabled(enabled)
        update_nested_config("banner", "enabled" => enabled)
      end

      def set_session_auto_resume_enabled(enabled)
        update_nested_config("sessions", "auto_resume" => enabled)
      end

      def configure_tools_settings
        selected = @prompt.select("Tools & Search", tools_setting_choices, title: "Settings")
        case selected.to_s.downcase
        when /\Aenable web search/, /\Adisable web search/
          set_web_search_enabled(!web_search_enabled?)
          @prompt.say("\nWeb search #{web_search_enabled? ? "enabled" : "disabled"}.\n")
        when /\Aweb search provider/
          configure_web_search_provider
        when /\Aallow model-provider/, /\Adisallow model-provider/
          set_web_search_allow_model_providers(!web_search_allow_model_providers?)
          @prompt.say("\nModel-provider web search #{web_search_allow_model_providers? ? "enabled" : "disabled"}.\n")
        when /\Aenable workspace guardrails/, /\Adisable workspace guardrails/
          set_workspace_guardrails_enabled(!workspace_guardrails_enabled?)
          @prompt.say("\nWorkspace guardrails #{workspace_guardrails_enabled? ? "enabled" : "disabled"}.\n")
        end
      end

      def tools_setting_choices
        [
          "#{web_search_enabled? ? "Disable" : "Enable"} web search (currently #{on_off(web_search_enabled?)})",
          "Web search provider (#{web_search_provider})",
          "#{web_search_allow_model_providers? ? "Disallow" : "Allow"} model-provider web search (currently #{on_off(web_search_allow_model_providers?)})",
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

      def set_web_search_enabled(enabled)
        update_nested_config("web_search", "enabled" => enabled)
      end

      def set_web_search_allow_model_providers(enabled)
        update_nested_config("web_search", "allow_model_providers" => enabled)
      end

      def set_workspace_guardrails_enabled(enabled)
        update_nested_config("tools", "workspace_guardrails" => enabled)
      end

      def configure_context_settings
        selected = @prompt.select("Context & Compaction", context_setting_choices, title: "Settings")
        case selected.to_s.downcase
        when /\Aenable auto-compaction/, /\Adisable auto-compaction/
          set_compaction_enabled(!compaction_enabled?)
          @prompt.say("\nAuto-compaction #{compaction_enabled? ? "enabled" : "disabled"}.\n")
        else
          @prompt.say("\n#{auto_compaction_status_line}\n") if selected.to_s.downcase.start_with?("status")
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

      def set_compaction_enabled(enabled)
        update_nested_config("compaction", "enabled" => enabled)
      end

      def configure_personalization_settings(conversation)
        selected = @prompt.select("Personalization", personalization_setting_choices(conversation), title: "Settings")
        case selected.to_s.downcase
        when /\Adefault persona/
          configure_default_persona(conversation)
        when /\Aactive instructions/
          show_active_instructions_summary(conversation)
        end
      end

      def personalization_setting_choices(conversation)
        [
          "Default persona (#{default_persona_label})",
          "Active instructions summary",
          "Back"
        ]
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
          @prompt.say("\nNo configured personas found. Edit #{ConfigFiles.config_path} to add personas.\n")
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
        lines = ["Active persona: #{label || "none"}"]
        lines << "Global AGENTS.md: #{ConfigFiles.agents_prompt ? "present" : "absent"}"
        lines << "Workspace AGENTS.md: #{ConfigFiles.workspace_agents_prompt(current_workspace_root) ? "present" : "absent"}"
        lines << "Messages: #{conversation.messages.length}" if conversation&.respond_to?(:messages)
        @prompt.say("\n#{lines.join("\n")}\n")
      end

      def configure_logging_settings
        selected = @prompt.select("Logging", logging_setting_choices, title: "Settings")
        key = logging_key_for_choice(selected)
        return unless key

        set_logging_value(key, !logging_enabled?(key))
        @prompt.say("\nLogging #{key.tr("_", " ")} #{logging_enabled?(key) ? "enabled" : "disabled"}.\n")
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
        update_nested_config("logging", key => value)
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
        @prompt.say("\n#{lines.join("\n")}\n")
      end

      def update_nested_config(section, values)
        config = ConfigFiles.read_config
        current = config[section].is_a?(Hash) ? config[section].dup : {}
        config[section] = current.merge(values)
        ConfigFiles.write_config(config)
        config
      end

      def on_off(value)
        value ? "on" : "off"
      end

      def login_interactively
        unless login_picker_available?
          @prompt.say("\nLogin provider picker is unavailable in this prompt.\n")
          return
        end

        selected = @prompt.select("OAuth provider", login_provider_choices, title: "Login")
        provider = selected_login_provider(selected)
        return unless provider

        run_busy_local_command_and_requeue(activity: "running") do
          login(provider: provider)
          reload_client_config
        end
      rescue StandardError => e
        @prompt.say("\nLogin error: #{e.message}\n")
      end

      def configure_model(conversation = nil, models: nil)
        unless model_overlay_available?
          @prompt.say("\nModel overlay is unavailable in this prompt.\n")
          return
        end

        models ||= normalized_available_models
        choices = model_choices(models)
        selected = @prompt.select("Default model", choices, title: "Models", custom: true)
        return unless selected

        provider, model = selected_model(selected, models)
        raise "Model must be a non-empty string" if model.to_s.strip.empty?

        ConfigFiles.update_config(ModelInfo.config_values_for_selection(provider, model))
        reload_client_config
        refresh_conversation_runtime(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw)
      rescue StandardError => e
        @prompt.say("\nModel error: #{e.message}\n")
      end

      # Writes the openrouter catalog output for the terminal CLI flow.
      def print_openrouter_catalog
        unless @client.respond_to?(:openrouter_catalog)
          @prompt.say("\nOpenRouter catalog is unavailable for this client.\n")
          return
        end

        models = Array(@client.openrouter_catalog)
        if models.empty?
          @prompt.say("\nNo OpenRouter catalog models available.\n")
        else
          ids = models.map { |model| model[:id] || model["id"] || model }.map(&:to_s).reject(&:empty?)
          @prompt.say("\nOpenRouter catalog:\n#{ids.join("\n")}\n")
        end
      rescue StandardError => e
        @prompt.say("\nOpenRouter catalog error: #{e.message}\n")
      end

      def configure_reasoning(conversation = nil)
        unless model_overlay_available?
          @prompt.say("\nReasoning overlay is unavailable in this prompt.\n")
          return
        end

        choices = ModelInfo.reasoning_effort_choices(current_model_provider, current_model_id)
        if choices.empty?
          @prompt.say("\nReasoning effort is unavailable for #{current_model_provider} #{current_model_id}.\n")
          return
        end

        selected = @prompt.select("Reasoning effort", reasoning_choices(choices), title: "Reasoning")
        return unless selected

        effort, = choices.find { |_value, label| selected.to_s.downcase.start_with?(label.downcase) }
        raise "Reasoning effort must be one of: #{choices.map(&:first).join(", ")}" unless effort

        ConfigFiles.update_config(ModelInfo.reasoning_config_key_for_provider(current_model_provider) => effort)
        reload_client_config
        refresh_conversation_runtime(conversation)
        @prompt.redraw if @prompt.respond_to?(:redraw)
      rescue StandardError => e
        @prompt.say("\nReasoning error: #{e.message}\n")
      end

      def login_picker_available?
        @prompt.respond_to?(:select)
      end

      def login_provider_choices
        ["OpenAI", "Anthropic", "OpenRouter", "GitHub"]
      end

      def selected_login_provider(selected)
        case selected.to_s.downcase
        when /\Aopenai\b/
          "openai"
        when /\Aanthropic\b/, /\Aclaude\b/
          "anthropic"
        when /\Aopenrouter\b/
          "openrouter"
        when /\Agithub\b/
          "github"
        end
      end

      def model_overlay_available?
        @prompt.respond_to?(:select)
      end

      def settings_overlay_available?
        @prompt.respond_to?(:select) && @prompt.respond_to?(:update_overlay_settings)
      end

      def choose_overlay_setting(message, choices, values)
        choice = @prompt.select(message, choices, title: "Settings")
        return nil unless choice

        values.find { |value| choice.to_s.downcase.start_with?(value) }
      end

      def normalized_available_models
        current_provider = @client.respond_to?(:current_provider) ? @client.current_provider : "Codex"
        current_model = @client.respond_to?(:current_model) ? @client.current_model : nil
        current_reasoning = @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort : nil
        models = @client.respond_to?(:available_models) ? Array(@client.available_models) : []
        models.map do |model|
          ModelInfo.normalize(
            model,
            current_provider: current_provider,
            current_model: current_model,
            current_reasoning_effort: current_reasoning
          )
        end
      end

      def model_choices(models)
        choices = models.map do |model|
          label = "#{model[:provider]} #{model[:id]}"
          label += " (current)" if model[:current]
          label
        end
        choices.empty? ? ["#{current_model_provider} #{current_model_id} (current)"] : choices.uniq
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

      def reasoning_choices(choices)
        current = @client.respond_to?(:current_reasoning_effort) ? @client.current_reasoning_effort.to_s : ModelInfo::DEFAULT_REASONING_EFFORT
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
