require "securerandom"
require "thread"
require_relative "../client"
require_relative "../openai_oauth"

module Kward
  module RPC
    class AuthManager
      Login = Struct.new(:id, :oauth, :pkce, :state, :server, :redirect_uri, :status, :error, :thread, keyword_init: true)

      def initialize(server:, oauth_factory: -> { OpenAIOAuth.new })
        @server = server
        @oauth_factory = oauth_factory
        @logins = {}
        @mutex = Mutex.new
      end

      def status
        oauth = @oauth_factory.call
        {
          openaiOAuth: oauth.logged_in?,
          openaiAccountId: oauth.respond_to?(:account_id) ? oauth.account_id : nil,
          openrouterApiKey: !ENV["OPENROUTER_API_KEY"].to_s.empty?,
          openaiAccessToken: !ENV["OPENAI_ACCESS_TOKEN"].to_s.empty?
        }
      rescue StandardError => e
        { openaiOAuth: false, error: e.message }
      end

      def start_openai_login(timeout_seconds: 120)
        oauth = @oauth_factory.call
        pkce = oauth.send(:generate_pkce)
        state = oauth.send(:random_urlsafe, 32)
        server = oauth.send(:start_callback_server)
        redirect_uri = "http://localhost:#{server.addr[1]}#{OpenAIOAuth::CALLBACK_PATH}"
        url = oauth.authorization_url(redirect_uri: redirect_uri, code_challenge: pkce[:challenge], state: state)
        login = Login.new(
          id: SecureRandom.uuid,
          oauth: oauth,
          pkce: pkce,
          state: state,
          server: server,
          redirect_uri: redirect_uri,
          status: "pending"
        )
        @mutex.synchronize { @logins[login.id] = login }
        login.thread = Thread.new { wait_for_callback(login, timeout_seconds: timeout_seconds.to_i <= 0 ? 120 : timeout_seconds.to_i) }
        { loginId: login.id, authorizationUrl: url, redirectUri: redirect_uri, status: login.status }
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

      def wait_for_callback(login, timeout_seconds:)
        code = login.oauth.send(:wait_for_callback, login.server, expected_state: login.state, timeout_seconds: timeout_seconds)
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

        tokens = login.oauth.send(:exchange_code_for_tokens, code: code, redirect_uri: login.redirect_uri, code_verifier: login.pkce[:verifier])
        login.oauth.save_auth(tokens: tokens)
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
          loginId: login.id,
          status: login.status,
          redirectUri: login.redirect_uri,
          error: login.error
        }.compact
      end
    end
  end
end
