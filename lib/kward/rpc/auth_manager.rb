require "securerandom"
require "thread"
require_relative "../auth/anthropic_oauth"
require_relative "../auth/github_oauth"
require_relative "../auth/openai_oauth"
require_relative "../model/client"
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
        oauth = @oauth_factory.call
        config = stored_config
        {
          openaiOAuth: oauth.logged_in?,
          openaiAccountId: oauth.respond_to?(:account_id) ? oauth.account_id : nil,
          openrouterApiKey: !ENV["OPENROUTER_API_KEY"].to_s.empty? || !config["openrouter_api_key"].to_s.empty?,
          openaiAccessToken: !ENV["OPENAI_ACCESS_TOKEN"].to_s.empty?,
          anthropicOAuth: @anthropic_oauth_factory.call.logged_in?,
          githubOAuth: @github_oauth_factory.call.logged_in?
        }
      rescue StandardError => e
        { openaiOAuth: false, error: e.message }
      end

      def providers
        { providers: [openai_provider, anthropic_provider, openrouter_provider, github_provider] }
      end

      def login_with_api_key(provider_id:, api_key:)
        provider_id = provider_id.to_s
        @config_manager.set_api_key(provider_id, api_key)
        { providerId: provider_id, message: "Saved API key for #{provider_name(provider_id)}." }
      end

      def logout_provider(provider_id:)
        provider_id = provider_id.to_s
        case provider_id
        when "openai"
          logout_openai
          { providerId: provider_id, message: "Logged out of OpenAI." }
        when "anthropic"
          logout_anthropic
          { providerId: provider_id, message: "Logged out of Anthropic." }
        when "openrouter"
          @config_manager.delete_key("openrouter_api_key")
          { providerId: provider_id, message: "Logged out of OpenRouter." }
        else
          raise "Unsupported auth provider: #{provider_id}"
        end
      end

      def login_with_oauth(provider_id:, timeout_seconds: 120)
        provider_id = provider_id.to_s
        case provider_id
        when "openai"
          start_oauth_login(provider_id: "openai", oauth: @oauth_factory.call, timeout_seconds: timeout_seconds)
        when "anthropic"
          start_oauth_login(provider_id: "anthropic", oauth: @anthropic_oauth_factory.call, timeout_seconds: timeout_seconds)
        when "github"
          raise "GitHub OAuth is supported in the CLI with `ruby lib/main.rb login github`, but RPC browser login is not implemented yet."
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

      def fetch_login(login_id)
        @mutex.synchronize { @logins[login_id.to_s] } || raise("Unknown login: #{login_id}")
      end

      def stored_config
        @config_manager.read(redacted: false)
      rescue StandardError
        {}
      end

      def openai_provider
        oauth = @oauth_factory.call
        env_configured = !ENV["OPENAI_ACCESS_TOKEN"].to_s.empty?
        stored_configured = oauth.logged_in?
        provider = {
          id: "openai",
          name: "OpenAI",
          authType: "oauth",
          configured: env_configured || stored_configured,
          storedCredentialType: "oauth",
          canLogout: stored_configured,
          usesCallbackServer: true
        }
        provider[:source] = env_configured ? "environment" : "stored" if provider[:configured]
        provider[:label] = provider[:configured] ? "Signed in" : "Not signed in"
        provider
      rescue StandardError
        {
          id: "openai",
          name: "OpenAI",
          authType: "oauth",
          configured: !ENV["OPENAI_ACCESS_TOKEN"].to_s.empty?,
          source: (!ENV["OPENAI_ACCESS_TOKEN"].to_s.empty? ? "environment" : nil),
          label: (!ENV["OPENAI_ACCESS_TOKEN"].to_s.empty? ? "Signed in" : "Not signed in"),
          storedCredentialType: "oauth",
          canLogout: false,
          usesCallbackServer: true
        }.compact
      end

      def anthropic_provider
        oauth = @anthropic_oauth_factory.call
        stored_configured = oauth.logged_in?
        provider = {
          id: "anthropic",
          name: "Anthropic",
          authType: "oauth",
          configured: stored_configured,
          storedCredentialType: "oauth",
          canLogout: stored_configured,
          usesCallbackServer: true
        }
        provider[:source] = "stored" if provider[:configured]
        provider[:label] = provider[:configured] ? "Signed in" : "Not signed in"
        provider
      rescue StandardError
        {
          id: "anthropic",
          name: "Anthropic",
          authType: "oauth",
          configured: false,
          label: "Not signed in",
          storedCredentialType: "oauth",
          canLogout: false,
          usesCallbackServer: true
        }
      end

      def openrouter_provider
        config = stored_config
        env_configured = !ENV["OPENROUTER_API_KEY"].to_s.empty?
        stored_configured = !config["openrouter_api_key"].to_s.empty?
        provider = {
          id: "openrouter",
          name: "OpenRouter",
          authType: "api_key",
          configured: env_configured || stored_configured,
          canLogout: stored_configured
        }
        provider[:source] = env_configured ? "environment" : "stored" if provider[:configured]
        provider[:storedCredentialType] = "api_key" if stored_configured
        provider[:label] = provider[:configured] ? "API key configured" : "API key not configured"
        provider
      end

      def github_provider
        oauth = @github_oauth_factory.call
        env_configured = !ENV["COPILOT_GITHUB_TOKEN"].to_s.empty?
        stored_configured = oauth.logged_in? && !env_configured
        provider = {
          id: "github",
          name: "GitHub",
          authType: "oauth",
          configured: env_configured || stored_configured,
          storedCredentialType: "oauth",
          canLogout: false,
          usesCallbackServer: false,
          supported: false,
          reason: "GitHub OAuth is available in the CLI for Copilot scaffolding; RPC login is not implemented yet."
        }
        provider[:source] = env_configured ? "environment" : "stored" if provider[:configured]
        provider[:label] = provider[:configured] ? "Signed in" : "Not signed in"
        provider
      rescue StandardError
        {
          id: "github",
          name: "GitHub",
          authType: "oauth",
          configured: false,
          label: "Not signed in",
          storedCredentialType: "oauth",
          canLogout: false,
          usesCallbackServer: false,
          supported: false,
          reason: "GitHub OAuth status unavailable."
        }
      end

      def provider_name(provider_id)
        case provider_id
        when "openrouter" then "OpenRouter"
        when "openai" then "OpenAI"
        when "anthropic" then "Anthropic"
        when "github" then "GitHub"
        else provider_id
        end
      end

      def logout_openai
        oauth = @oauth_factory.call
        path = oauth.auth_path if oauth.respond_to?(:auth_path)
        File.delete(path) if path && File.exist?(path)
      end

      def logout_anthropic
        oauth = @anthropic_oauth_factory.call
        path = oauth.auth_path if oauth.respond_to?(:auth_path)
        File.delete(path) if path && File.exist?(path)
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
