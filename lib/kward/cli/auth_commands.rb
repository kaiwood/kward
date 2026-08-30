# Namespace for the Kward CLI agent runtime.
module Kward
  # Command-line frontend that coordinates terminal interaction, sessions, tools, and model turns.
  class CLI
    # Login, logout, and credential-status commands mixed into the CLI frontend.
    module AuthCommands
      def handle_auth_command(arguments)
        if help_option_arguments?(arguments)
          print_command_help("auth")
          return
        end

        case arguments
        when ["status"]
          print_auth_status
        when ["status", "--all"]
          print_auth_status(show_all: true)
        when ["logout"]
          logout_auth
        else
          raise ArgumentError, command_usage("auth")
        end
      end

      # Writes the auth status output for the terminal CLI flow.
      def print_auth_status(show_all: false)
        credentials = auth_credentials
        configured, missing = credentials.partition { |credential| credential.fetch(:configured) }
        lines = [colored("Authentication", :green, :bold), "", colored("Configured", :blue, :bold)]
        lines.concat(auth_credential_lines(configured, status: :ok, empty_message: "None"))

        if show_all
          lines << ""
          lines << colored("Not configured", :blue, :bold)
          lines.concat(auth_credential_lines(missing, status: :optional, empty_message: "None"))
        elsif missing.any?
          lines << ""
          lines << "#{missing.length} other provider#{missing.length == 1 ? " is" : "s are"} not configured. Run `kward auth status --all` for details."
        end

        lines << ""
        lines << colored("Credential directory", :blue, :bold)
        lines << "  #{ConfigFiles.config_dir}"
        @prompt.say lines.join("\n")
      end

      def auth_credentials
        store = api_key_store
        store.migrate_openrouter_config_key!
        credentials = [
          { label: "OpenAI OAuth", configured: File.exist?(OpenAIOAuth.default_auth_path) },
          { label: "Anthropic OAuth", configured: File.exist?(AnthropicOAuth.default_auth_path) },
          { label: "GitHub OAuth", configured: File.exist?(GithubOAuth.default_auth_path) }
        ]
        credentials.concat ProviderCatalog.api_key_providers.map { |provider| { label: "#{provider.name} API key", configured: store.configured?(provider.id) } }
      end

      def auth_credential_lines(credentials, status:, empty_message:)
        return ["  #{empty_message}"] if credentials.empty?

        credentials.map { |credential| "  #{doctor_mark(status)} #{credential.fetch(:label)}" }
      end

      def logout_auth
        removed = []
        [OpenAIOAuth.default_auth_path, AnthropicOAuth.default_auth_path, GithubOAuth.default_auth_path].each do |path|
          next unless File.exist?(path)

          File.delete(path)
          removed << path
        end
        store = api_key_store
        store.migrate_openrouter_config_key!
        ProviderCatalog.api_key_providers.each do |provider|
          removed << "#{provider.name} API key" if store.delete(provider.id)
        end

        if removed.empty?
          @prompt.say "No saved credentials found."
        else
          @prompt.say "Removed #{removed.length} saved credential#{removed.length == 1 ? "" : "s"}."
        end
      end

      def login(provider: nil, oauth: nil, auth_method: nil)
        provider = normalized_login_provider(provider)
        if api_key_login?(provider, auth_method)
          login_with_api_key(provider)
          return
        end

        oauth ||= case provider
                  when "github", "copilot" then GithubOAuth.new
                  when "anthropic" then AnthropicOAuth.new
                  else OpenAIOAuth.new
                  end
        path = oauth.login(prompt: @prompt)
        name = case provider
               when "github", "copilot" then "GitHub"
               when "anthropic" then "Anthropic"
               else "OpenAI"
               end
        @prompt.say("#{colored("Saved", :green, :bold)} #{name} OAuth login to #{path}")
      end

      private

      def api_key_store
        @api_key_store ||= APIKeyStore.new
      end

      def normalized_login_provider(provider)
        value = provider.to_s.downcase
        return "openai" if value.empty?
        return "anthropic" if ["anthropic", "claude"].include?(value)
        return "copilot" if ["github", "copilot"].include?(value)

        ProviderCatalog.fetch(value).id
      end

      def api_key_login?(provider, auth_method)
        return true if auth_method == :api_key || auth_method == "api_key"

        ProviderCatalog.fetch(provider).api_key? && !["openai", "anthropic", "copilot"].include?(provider)
      end

      def login_with_api_key(provider_id)
        provider = ProviderCatalog.fetch(provider_id)
        raise "#{provider.name} does not accept an API key" unless provider.api_key?

        api_key = @prompt.ask("#{provider.name} API key:").to_s.strip
        provider_config = provider_config_after_api_key_login(provider)
        models = refresh_provider_models(provider, api_key)
        path = api_key_store.store(provider.id, api_key)
        ConfigFiles.update_config(provider_config) unless provider_config.empty?
        @prompt.say("#{colored("Saved", :green, :bold)} #{provider.name} API key to #{path}")
        @prompt.say("Loaded #{models.length} #{provider.name} model#{models.length == 1 ? "" : "s"}.") if models
      end

      def refresh_provider_models(provider, api_key)
        return unless ProviderCatalog.runtime(provider.id).automatic_model_discovery?

        model_catalog(provider_id: provider.id, api_key: api_key).refresh
      end

      def model_catalog(provider_id:, api_key:)
        ModelCatalog.new(provider_id: provider_id, api_key: api_key)
      end

      def provider_config_after_api_key_login(provider)
        return {} unless provider.id == "azure_openai"

        AzureOpenAIConfig.new(
          endpoint: @prompt.ask("Azure OpenAI endpoint:"),
          deployment: @prompt.ask("Azure OpenAI deployment name:"),
          api_version: @prompt.ask("Azure OpenAI API version:")
        ).to_config
      end

    end
  end
end
