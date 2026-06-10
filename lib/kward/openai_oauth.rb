require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "time"
require "uri"

module Kward
  class OpenAIOAuth
    ISSUER = "https://auth.openai.com"
    TOKEN_URL = URI("#{ISSUER}/oauth/token")
    DEFAULT_PORT = 1455
    CALLBACK_PATH = "/auth/callback"
    SCOPE = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    attr_reader :auth_path

    def initialize(auth_path: OpenAIOAuth.default_auth_path, client_id: nil, config_path: OpenAIOAuth.default_config_path, issuer: ISSUER)
      @auth_path = File.expand_path(auth_path)
      @client_id = client_id
      @config_path = File.expand_path(config_path)
      @issuer = issuer.delete_suffix("/")
    end

    def self.default_auth_path
      File.expand_path(ENV["KWARD_AUTH_PATH"] || "~/.kward/auth.json")
    end

    def self.default_config_path
      File.expand_path(ENV["KWARD_CONFIG_PATH"] || "~/.kward/config.json")
    end

    def access_token
      auth = current_auth
      auth&.fetch("tokens", {})&.fetch("access_token", nil)
    end

    def account_id
      auth = current_auth
      auth&.fetch("account_id", nil) || auth&.fetch("tokens", {})&.fetch("account_id", nil)
    end

    def logged_in?
      !access_token.to_s.empty?
    end

    def login(prompt:, open_browser: true, timeout_seconds: 120)
      pkce = generate_pkce
      state = random_urlsafe(32)
      server = start_callback_server
      redirect_uri = "http://localhost:#{server.addr[1]}#{CALLBACK_PATH}"
      url = authorization_url(redirect_uri: redirect_uri, code_challenge: pkce[:challenge], state: state)

      prompt.say("OpenAI login URL:\n#{url}\n")
      prompt.say("Waiting for browser login. If it does not complete, paste the callback URL when prompted.")
      browser_opened = open_browser && open_url(url)

      code = wait_for_callback(server, expected_state: state, timeout_seconds: browser_opened ? timeout_seconds : 5)
      unless code
        input = prompt.ask("Paste callback URL or authorization code:")
        code = authorization_code_from(input.to_s, expected_state: state)
      end
      raise "Missing authorization code" if code.to_s.empty?

      tokens = exchange_code_for_tokens(code: code, redirect_uri: redirect_uri, code_verifier: pkce[:verifier])
      save_auth(tokens: tokens)
      auth_path
    ensure
      server&.close unless server&.closed?
    end

    def authorization_url(redirect_uri:, code_challenge:, state:)
      query = URI.encode_www_form(
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        scope: SCOPE,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        id_token_add_organizations: "true",
        codex_cli_simplified_flow: "true",
        state: state,
        originator: "kward"
      )
      "#{@issuer}/oauth/authorize?#{query}"
    end

    def authorization_code_from(input, expected_state: nil)
      value = input.strip
      return "" if value.empty?

      uri = URI.parse(value)
      params = URI.decode_www_form(uri.query.to_s).to_h
      if params.key?("code")
        raise "OAuth state mismatch" if expected_state && params["state"] != expected_state

        return params["code"]
      end

      value
    rescue URI::InvalidURIError
      value
    end

    def save_auth(tokens: {})
      FileUtils.mkdir_p(File.dirname(@auth_path), mode: 0o700)
      account_id = extract_account_id(tokens)
      data = {
        "auth_mode" => "openai_oauth",
        "tokens" => account_id ? tokens.merge("account_id" => account_id) : tokens,
        "account_id" => account_id,
        "saved_at" => Time.now.utc.iso8601,
        "expires_at" => expires_at_for(tokens)
      }.compact

      File.open(@auth_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.pretty_generate(data))
        file.write("\n")
      end
      File.chmod(0o600, @auth_path)
    end

    def refresh!
      auth = load_auth || raise("OpenAI OAuth login not found")
      refresh_token = auth.fetch("tokens", {}).fetch("refresh_token", nil)
      raise "OpenAI OAuth refresh token not found" if refresh_token.to_s.empty?

      response = post_json(TOKEN_URL,
        client_id: client_id,
        grant_type: "refresh_token",
        refresh_token: refresh_token)
      refreshed = parse_successful_json(response, "OpenAI OAuth token refresh")
      save_auth(tokens: (auth.fetch("tokens", {}) || {}).merge(refreshed))
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

      value = load_config.fetch("openai_oauth_client_id", "").to_s.strip
      return value unless value.empty?

      raise "OpenAI OAuth client_id is not configured. Add openai_oauth_client_id to #{@config_path}."
    end

    def load_config
      raise "Kward config not found: #{@config_path}" unless File.exist?(@config_path)

      JSON.parse(File.read(@config_path))
    rescue JSON::ParserError
      raise "Invalid Kward config JSON: #{@config_path}"
    end

    def generate_pkce
      verifier = random_urlsafe(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      { verifier: verifier, challenge: challenge }
    end

    def random_urlsafe(bytes)
      Base64.urlsafe_encode64(SecureRandom.random_bytes(bytes), padding: false)
    end

    def start_callback_server
      TCPServer.new("localhost", Integer(ENV.fetch("KWARD_OAUTH_PORT", DEFAULT_PORT)))
    rescue Errno::EADDRINUSE
      TCPServer.new("localhost", 0)
    end

    def wait_for_callback(server, expected_state:, timeout_seconds:)
      ready = IO.select([server], nil, nil, timeout_seconds)
      return nil unless ready

      socket = server.accept
      request_line = socket.gets.to_s
      path = request_line.split[1].to_s
      params = URI.decode_www_form(URI.parse(path).query.to_s).to_h

      code = nil
      status = "200 OK"
      body = "Login complete. You can close this window."
      if params["error"]
        body = "Login failed. Return to the terminal."
      elsif params["state"] != expected_state
        status = "400 Bad Request"
        body = "Invalid OAuth state. Return to the terminal."
      else
        code = params["code"]
      end

      socket.write("HTTP/1.1 #{status}\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      code
    rescue URI::InvalidURIError
      nil
    ensure
      socket&.close
    end

    def exchange_code_for_tokens(code:, redirect_uri:, code_verifier:)
      response = post_form(TOKEN_URL,
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: client_id,
        code_verifier: code_verifier)
      parse_successful_json(response, "OpenAI OAuth token exchange")
    end

    def post_form(uri, params)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.body = URI.encode_www_form(params)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    end

    def post_json(uri, params)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.dump(params)

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    end

    def token_expired?(auth)
      expires_at = auth&.fetch("expires_at", nil)
      return false unless expires_at

      Time.parse(expires_at) <= Time.now.utc + 60
    rescue ArgumentError
      false
    end

    def expires_at_for(tokens)
      expires_in = tokens["expires_in"] || tokens[:expires_in]
      return tokens["expires_at"] || tokens[:expires_at] unless expires_in

      (Time.now.utc + expires_in.to_i).iso8601
    end

    def extract_account_id(tokens)
      [tokens["id_token"], tokens[:id_token], tokens["access_token"], tokens[:access_token]].each do |token|
        claims = jwt_claims(token.to_s)
        account_id = claims["chatgpt_account_id"] || claims.dig("https://api.openai.com/auth", "chatgpt_account_id") || claims.dig("organizations", 0, "id")
        return account_id if account_id
      end
      nil
    end

    def jwt_claims(token)
      _header, payload, _signature = token.split(".")
      return {} unless payload

      JSON.parse(Base64.urlsafe_decode64(payload + "=" * ((4 - payload.length % 4) % 4)))
    rescue JSON::ParserError, ArgumentError
      {}
    end

    def parse_successful_json(response, label)
      raise "#{label} failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise "#{label} returned invalid JSON"
    end

    def open_url(url)
      command = if RUBY_PLATFORM.match?(/darwin/)
                  "open"
                elsif RUBY_PLATFORM.match?(/linux/)
                  "xdg-open"
                end
      return false unless command

      system(command, url, out: File::NULL, err: File::NULL)
    end
  end
end
