require "base64"
require "json"
require "time"
require "uri"
require_relative "file"
require_relative "oauth_helpers"
require_relative "../config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # OAuth helper for Anthropic Claude Pro/Max subscription credentials.
  class AnthropicOAuth
    include OAuthHelpers

    AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
    TOKEN_URL = URI("https://platform.claude.com/v1/oauth/token")
    DEFAULT_PORT = 53_692
    CALLBACK_PATH = "/callback"
    DEFAULT_CLIENT_ID = Base64.decode64("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
    SCOPE = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    attr_reader :auth_path

    # Creates an object for Anthropic OAuth credentials.
    def initialize(auth_path: AnthropicOAuth.default_auth_path, client_id: nil, config_path: ConfigFiles.config_path)
      @auth_path = File.expand_path(auth_path)
      @client_id = client_id
      @config_path = File.expand_path(config_path)
    end

    def self.default_auth_path
      File.expand_path(ENV["KWARD_ANTHROPIC_AUTH_PATH"] || "~/.kward/anthropic_auth.json")
    end

    def access_token
      auth = current_auth
      auth&.fetch("tokens", {})&.fetch("access_token", nil)
    end

    def logged_in?
      !access_token.to_s.empty?
    end

    def login(prompt:, open_browser: true, timeout_seconds: 120)
      flow = start_login_flow
      pkce = flow[:pkce]
      state = flow[:state]
      server = flow[:server]
      redirect_uri = flow[:redirect_uri]
      url = flow[:authorization_url]

      prompt.say("Anthropic login URL:\n#{url}\n")
      prompt.say("Waiting for browser login. If it does not complete, paste the callback URL when prompted.")
      browser_opened = open_browser && open_url(url)

      code = wait_for_callback(server, expected_state: state, timeout_seconds: browser_opened ? timeout_seconds : 5)
      unless code
        input = prompt.ask("Paste callback URL or authorization code:")
        code = authorization_code_from(input.to_s, expected_state: state)
      end
      raise "Missing authorization code" if code.to_s.empty?

      complete_login_flow(code: code, redirect_uri: redirect_uri, code_verifier: pkce[:verifier], state: state)
      auth_path
    ensure
      server&.close unless server&.closed?
    end

    def authorization_url(redirect_uri:, code_challenge:, state:)
      query = URI.encode_www_form(
        client_id: client_id,
        response_type: "code",
        redirect_uri: redirect_uri,
        scope: SCOPE,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        state: state
      )
      "#{AUTHORIZE_URL}?#{query}"
    end

    def start_login_flow
      pkce = generate_pkce
      state = pkce[:verifier]
      server = start_callback_server
      redirect_uri = "http://localhost:#{server.addr[1]}#{CALLBACK_PATH}"
      {
        pkce: pkce,
        state: state,
        server: server,
        redirect_uri: redirect_uri,
        authorization_url: authorization_url(redirect_uri: redirect_uri, code_challenge: pkce[:challenge], state: state)
      }
    end

    def wait_for_login_callback(server, expected_state:, timeout_seconds:)
      wait_for_callback(server, expected_state: expected_state, timeout_seconds: timeout_seconds)
    end

    def complete_login_flow(code:, redirect_uri:, code_verifier:, state:)
      tokens = exchange_code_for_tokens(code: code, redirect_uri: redirect_uri, code_verifier: code_verifier, state: state)
      save_auth(tokens: tokens)
      tokens
    end

    def authorization_code_from(input, expected_state: nil)
      value = input.strip
      return "" if value.empty?

      uri = URI.parse(value)
      params = URI.decode_www_form(uri.query.to_s).to_h
      if params.key?("code")
        raise "OAuth state mismatch" if expected_state && params["state"].to_s != expected_state.to_s

        return params["code"]
      end

      if value.include?("#")
        code, state = value.split("#", 2)
        raise "OAuth state mismatch" if expected_state && !state.to_s.empty? && state != expected_state

        return code
      end

      value
    rescue URI::InvalidURIError
      value
    end

    def save_auth(tokens: {})
      data = {
        "auth_mode" => "anthropic_oauth",
        "tokens" => tokens,
        "saved_at" => Time.now.utc.iso8601,
        "expires_at" => expires_at_for(tokens)
      }.compact

      AuthFile.write_json(@auth_path, data)
    end

    # Performs refresh for Anthropic OAuth credentials.
    def refresh!
      auth = load_auth || raise("Anthropic OAuth login not found")
      refresh_token = auth.fetch("tokens", {}).fetch("refresh_token", nil)
      raise "Anthropic OAuth refresh token not found" if refresh_token.to_s.empty?

      response = post_json(TOKEN_URL,
        grant_type: "refresh_token",
        client_id: client_id,
        refresh_token: refresh_token)
      refreshed = parse_successful_json(response, "Anthropic OAuth token refresh")
      save_auth(tokens: auth.fetch("tokens", {}).merge(refreshed))
      load_auth
    end

    private

    def current_auth
      auth = load_auth
      tokens = auth&.fetch("tokens", {}) || {}
      return nil if tokens.empty?

      if token_expired?(auth) && !tokens["refresh_token"].to_s.empty?
        auth = refresh!
      end

      auth
    end

    def load_auth
      return nil unless File.exist?(@auth_path)

      JSON.parse(File.read(@auth_path))
    rescue JSON::ParserError
      nil
    end

    def client_id
      return @client_id unless @client_id.to_s.strip.empty?

      value = ENV["ANTHROPIC_OAUTH_CLIENT_ID"].to_s.strip
      return value unless value.empty?

      value = ConfigFiles.config_value(ConfigFiles.read_config(@config_path), "anthropic_oauth_client_id")
      return value unless value.to_s.empty?

      DEFAULT_CLIENT_ID
    end

    def start_callback_server
      oauth_callback_server(port_env: "KWARD_ANTHROPIC_OAUTH_PORT", default_port: DEFAULT_PORT)
    end

    def exchange_code_for_tokens(code:, redirect_uri:, code_verifier:, state:)
      response = post_json(TOKEN_URL,
        grant_type: "authorization_code",
        client_id: client_id,
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: code_verifier,
        state: state)
      parse_successful_json(response, "Anthropic OAuth token exchange")
    end

    def post_json(uri, params = nil, **keyword_params)
      super(uri, params, headers: { "Accept" => "application/json" }, **keyword_params)
    end
  end
end
