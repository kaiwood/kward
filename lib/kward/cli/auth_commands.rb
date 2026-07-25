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
        when ["logout"]
          logout_auth
        else
          raise ArgumentError, command_usage("auth")
        end
      end

      # Writes the auth status output for the terminal CLI flow.
      def print_auth_status
        store = api_key_store
        store.migrate_openrouter_config_key!
        lines = ["#{colored("Auth Status", :green, :bold)}", ""]
        lines << auth_status_line("OpenAI OAuth", File.exist?(OpenAIOAuth.default_auth_path), OpenAIOAuth.default_auth_path)
        lines << auth_status_line("Anthropic OAuth", File.exist?(AnthropicOAuth.default_auth_path), AnthropicOAuth.default_auth_path)
        lines << auth_status_line("GitHub OAuth", File.exist?(GithubOAuth.default_auth_path), GithubOAuth.default_auth_path)
        ProviderCatalog.api_key_providers.each do |provider|
          lines << auth_status_line("#{provider.name} API key", store.configured?(provider.id), store.path)
        end
        @prompt.say lines.join("\n")
      end

      def auth_status_line(label, configured, location)
        status = configured ? :ok : :warning
        message = configured ? "configured" : "not configured"
        "#{doctor_mark(status)} #{label}: #{message} (#{location})"
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
        models = refresh_provider_models(provider, api_key)
        path = api_key_store.store(provider.id, api_key)
        configure_provider_after_api_key_login(provider)
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

      def configure_provider_after_api_key_login(provider)
        return unless provider.id == "azure_openai"

        endpoint = @prompt.ask("Azure OpenAI endpoint:").to_s.strip
        deployment = @prompt.ask("Azure OpenAI deployment name:").to_s.strip
        raise "Azure OpenAI endpoint must be a non-empty string" if endpoint.empty?
        raise "Azure OpenAI deployment name must be a non-empty string" if deployment.empty?

        ConfigFiles.update_config("azure_openai_endpoint" => endpoint, "azure_openai_model" => deployment)
      end

    end
  end
end
