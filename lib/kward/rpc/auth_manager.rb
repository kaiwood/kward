require "securerandom"
require "thread"
require_relative "../auth/anthropic_oauth"
require_relative "../auth/github_oauth"
require_relative "../auth/openai_oauth"
require_relative "../model/client"
require_relative "../model/provider_catalog"
require_relative "config_manager"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # RPC authentication manager for provider status, login, and logout requests.
    class AuthManager
      Login = Struct.new(:id, :provider_id, :oauth, :pkce, :state, :server, :redirect_uri, :status, :error, :thread, keyword_init: true)

      def initialize(server:, oauth_factory: -> { OpenAIOAuth.new }, github_oauth_factory: -> { GithubOAuth.new }, anthropic_oauth_factory: -> { AnthropicOAuth.new }, config_manager: ConfigManager.new)
        @server = server
        @oauth_factory = oauth_factory
        @github_oauth_factory = github_oauth_factory
        @anthropic_oauth_factory = anthropic_oauth_factory
        @config_manager = config_manager
        @logins = {}
        @mutex = Mutex.new
      end

      def status
        provider_status = providers.fetch(:providers)
        {
          providers: provider_status,
          openaiOAuth: oauth_status("openai")[:configured],
          openrouterApiKey: @config_manager.api_key_status("openrouter")[:configured],
          openaiAccessToken: !ENV["OPENAI_ACCESS_TOKEN"].to_s.empty?,
          anthropicOAuth: oauth_status("anthropic")[:configured],
          githubOAuth: oauth_status("copilot")[:configured]
        }
      rescue StandardError => e
        { providers: [], openaiOAuth: false, error: e.message }
      end

      def providers
        { providers: ProviderCatalog.all.map { |provider| provider_payload(provider) } }
      end

      def login_with_api_key(provider_id:, api_key:, configuration: nil)
        raise ArgumentError, "API key must be a non-empty string" if api_key.to_s.strip.empty?

        provider = ProviderCatalog.fetch(provider_id)
        @config_manager.configure_azure_openai(configuration || {}) if provider.id == "azure_openai"
        @config_manager.set_api_key(provider.id, api_key)
        { providerId: provider.id, authMethod: "api_key", configured: true, message: "Saved API key for #{provider.name}." }
      end

      def logout_provider(provider_id:, auth_method: nil)
        provider = ProviderCatalog.fetch(provider_id)
        auth_method = auth_method.to_s unless auth_method.nil?
        removed = false
        if provider.api_key? && (auth_method.nil? || auth_method == "api_key")
          removed = @config_manager.delete_api_key(provider.id) || removed
        end
        if provider.oauth? && (auth_method.nil? || auth_method == "oauth")
          removed = logout_oauth_provider(provider.id) || removed
        end

        { providerId: provider.id, authMethod: auth_method, removed: removed, message: "Logged out of #{provider.name}." }.compact
      end

      def login_with_oauth(provider_id:, timeout_seconds: 120)
        provider_id = provider_id.to_s
        case provider_id
        when "openai"
          start_oauth_login(provider_id: "openai", oauth: @oauth_factory.call, timeout_seconds: timeout_seconds)
        when "anthropic"
          start_oauth_login(provider_id: "anthropic", oauth: @anthropic_oauth_factory.call, timeout_seconds: timeout_seconds)
        when "github", "copilot"
          raise "GitHub Copilot OAuth is unavailable over RPC; use the interactive CLI login."
        when "openrouter"
          raise "OpenRouter OAuth is unavailable because Kward has not implemented OpenRouter's official PKCE flow."
        when "xai"
          raise "xAI OAuth is unavailable because no official stable third-party flow is supported."
        else
          raise "Unsupported OAuth provider: #{provider_id}"
        end
      end

      def start_openai_login(timeout_seconds: 120)
        start_oauth_login(provider_id: "openai", oauth: @oauth_factory.call, timeout_seconds: timeout_seconds)
      end

      def start_oauth_login(provider_id:, oauth:, timeout_seconds: 120)
        flow = oauth.start_login_flow
        pkce = flow.fetch(:pkce)
        state = flow.fetch(:state)
        server = flow.fetch(:server)
        redirect_uri = flow.fetch(:redirect_uri)
        url = flow.fetch(:authorization_url)
        login = Login.new(
          id: SecureRandom.uuid,
          provider_id: provider_id,
          oauth: oauth,
          pkce: pkce,
          state: state,
          server: server,
          redirect_uri: redirect_uri,
          status: "pending"
        )
        @mutex.synchronize { @logins[login.id] = login }
        login.thread = Thread.new { wait_for_callback(login, timeout_seconds: timeout_seconds.to_i <= 0 ? 120 : timeout_seconds.to_i) }
        { providerId: provider_id, loginId: login.id, authorizationUrl: url, redirectUri: redirect_uri, status: login.status }
      end

      def submit_openai_code(login_id:, code:)
        login = fetch_login(login_id)
        raise "Login is not pending" unless login.status == "pending"

        code = login.oauth.authorization_code_from(code.to_s, expected_state: login.state)
        complete_login(login, code)
        login_payload(login)
      end

      def login_status(login_id:)
        login_payload(fetch_login(login_id))
      end

      private

      def provider_payload(provider)
        methods = []
        if provider.api_key?
          status = @config_manager.api_key_status(provider.id)
          methods << {
            id: "api_key",
            supported: true,
            configured: status[:configured],
            source: status[:source],
            canLogout: status[:canLogout]
          }.compact
        end
        methods << oauth_method_payload(provider) if provider.oauth?
        configured_methods = methods.select { |method| method[:configured] }
        preferred = methods.find { |method| method[:id] == "oauth" } || methods.first
        {
          id: provider.id,
          runtimeId: ProviderCatalog.runtime(provider.id).id,
          name: provider.name,
          authType: preferred&.fetch(:id, nil),
          authMethods: methods,
          configured: !configured_methods.empty?,
          source: configured_methods.find { |method| method[:source] == "environment" }&.fetch(:source, nil) || configured_methods.first&.fetch(:source, nil),
          canLogout: configured_methods.any? { |method| method[:canLogout] },
          usesCallbackServer: methods.any? { |method| method[:usesCallbackServer] },
          label: configured_methods.empty? ? "Not configured" : "Configured"
        }.compact
      end

      def oauth_method_payload(provider)
        status = oauth_status(provider.id)
        supported = ["openai", "anthropic"].include?(provider.id)
        reason = unless supported
                   case provider.id
                   when "openrouter"
                     "Official PKCE is documented, but Kward has not implemented it."
                   when "xai"
                     "No official stable third-party OAuth flow is available."
                   else
                     "OAuth login is available only in the interactive CLI."
                   end
                 end
        {
          id: "oauth",
          name: provider.oauth_name,
          supported: supported,
          configured: status[:configured],
          source: status[:source],
          canLogout: status[:canLogout],
          usesCallbackServer: supported,
          reason: reason
        }.compact
      end

      def oauth_status(provider_id)
        case provider_id
        when "openai"
          oauth_credential_status(@oauth_factory.call, env_name: "OPENAI_ACCESS_TOKEN")
        when "anthropic"
          oauth_credential_status(@anthropic_oauth_factory.call)
        when "copilot"
          oauth_credential_status(@github_oauth_factory.call, env_name: "COPILOT_GITHUB_TOKEN", can_logout: false)
        else
          { configured: false, canLogout: false }
        end
      rescue StandardError
        { configured: false, canLogout: false }
      end

      def oauth_credential_status(oauth, env_name: nil, can_logout: true)
        environment = env_name && !ENV[env_name].to_s.empty?
        stored = oauth.logged_in?
        {
          configured: environment || stored,
          source: environment ? "environment" : (stored ? "stored" : nil),
          canLogout: can_logout && stored
        }.compact
      end

      def logout_oauth_provider(provider_id)
        oauth = case provider_id
                when "openai" then @oauth_factory.call
                when "anthropic" then @anthropic_oauth_factory.call
                else return false
                end
        path = oauth.auth_path if oauth.respond_to?(:auth_path)
        return false unless path && File.exist?(path)

        File.delete(path)
        true
      end

      def fetch_login(login_id)
        @mutex.synchronize { @logins[login_id.to_s] } || raise("Unknown login: #{login_id}")
      end

      def wait_for_callback(login, timeout_seconds:)
        code = login.oauth.wait_for_login_callback(login.server, expected_state: login.state, timeout_seconds: timeout_seconds)
        complete_login(login, code) unless code.to_s.empty?
      rescue StandardError => e
        login.status = "failed"
        login.error = e.message
        @server.notify("auth/loginFinished", login_payload(login))
      ensure
        login.server&.close unless login.server&.closed?
      end

      def complete_login(login, code)
        raise "Missing authorization code" if code.to_s.empty?

        login.oauth.complete_login_flow(code: code, redirect_uri: login.redirect_uri, code_verifier: login.pkce[:verifier])
        login.status = "completed"
        @server.notify("auth/loginFinished", login_payload(login))
      rescue StandardError => e
        login.status = "failed"
        login.error = e.message
        @server.notify("auth/loginFinished", login_payload(login))
        raise
      ensure
        login.server&.close unless login.server&.closed?
      end

      def login_payload(login)
        {
          providerId: provider_id_for_login(login),
          loginId: login.id,
          status: login.status,
          redirectUri: login.redirect_uri,
          message: login_status_message(login.status),
          error: login.error
        }.compact
      end

      def provider_id_for_login(login)
        login.provider_id || "openai"
      end

      def login_status_message(status)
        case status
        when "completed"
          "OAuth login completed."
        when "failed"
          "OAuth login failed."
        when "cancelled"
          "OAuth login cancelled."
        else
          "OAuth login pending."
        end
      end
    end
  end
end
