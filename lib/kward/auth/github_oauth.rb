require "json"
require "net/http"
require "time"
require "uri"
require_relative "file"
require_relative "../config_files"

# Namespace for the Kward CLI agent runtime.
module Kward
  # OAuth helper for GitHub Copilot credentials.
  class GithubOAuth
    DEVICE_CODE_URL = URI("https://github.com/login/device/code")
    TOKEN_URL = URI("https://github.com/login/oauth/access_token")
    COPILOT_TOKEN_URL = URI("https://api.github.com/copilot_internal/v2/token")
    DEFAULT_SCOPE = "read:user"
    DEFAULT_CLIENT_ID = "Iv1.b507a08c87ecfe98"
    COPILOT_HEADERS = {
      "User-Agent" => "GitHubCopilotChat/0.35.0",
      "Editor-Version" => "vscode/1.107.0",
      "Editor-Plugin-Version" => "copilot-chat/0.35.0",
      "Copilot-Integration-Id" => "vscode-chat"
    }.freeze

    attr_reader :auth_path

    # Creates an object for GitHub Copilot OAuth credentials.
    def initialize(auth_path: GithubOAuth.default_auth_path, config_path: ConfigFiles.config_path)
      @auth_path = File.expand_path(auth_path)
      @config_path = File.expand_path(config_path)
    end

    def self.default_auth_path
      File.expand_path(ENV["KWARD_GITHUB_AUTH_PATH"] || "~/.kward/github_auth.json")
    end

    def access_token
      env_token = ENV["COPILOT_GITHUB_TOKEN"].to_s
      return env_token unless env_token.empty?

      auth = load_auth
      return nil unless auth

      token = auth.dig("tokens", "copilot_access_token") || auth.dig("tokens", "access")
      return token if token && !token_expired?(auth)

      github_token = auth.dig("tokens", "github_access_token") || auth.dig("tokens", "refresh") || auth.dig("tokens", "access_token")
      return token unless github_token

      refreshed = refresh_copilot_token(github_token)
      save_auth(tokens: auth.fetch("tokens", {}).merge(refreshed))
      refreshed["copilot_access_token"]
    end

    def base_url
      token = access_token.to_s
      match = token.match(/proxy-ep=([^;]+)/)
      return "https://#{match[1].sub(/\Aproxy\./, "api.")}" if match

      "https://api.individual.githubcopilot.com"
    end

    def logged_in?
      !access_token.to_s.empty?
    end

    def login(prompt:, timeout_seconds: 900)
      device = request_device_code
      prompt.say("GitHub login URL: #{device.fetch("verification_uri")}")
      prompt.say("GitHub device code: #{device.fetch("user_code")}")
      prompt.say("Authorize Kward in your browser, then wait for login to complete.")

      github_tokens = poll_for_token(
        device_code: device.fetch("device_code"),
        interval: positive_integer(device["interval"]) || 5,
        timeout_seconds: timeout_seconds
      )
      copilot_tokens = refresh_copilot_token(github_tokens.fetch("access_token"))
      tokens = github_tokens.merge("github_access_token" => github_tokens.fetch("access_token")).merge(copilot_tokens)
      save_auth(tokens: tokens)
      auth_path
    end

    def save_auth(tokens: {})
      data = {
        "auth_mode" => "github_oauth",
        "tokens" => tokens,
        "saved_at" => Time.now.utc.iso8601,
        "expires_at" => expires_at_for(tokens)
      }.compact

      AuthFile.write_json(@auth_path, data)
    end

    private

    def refresh_copilot_token(github_token)
      response = get_json(COPILOT_TOKEN_URL, "Authorization" => "Bearer #{github_token}")
      data = parse_successful_json(response, "GitHub Copilot token")
      token = data["token"].to_s
      expires_at = data["expires_at"].to_i
      raise "GitHub Copilot token response missing token" if token.empty?

      {
        "copilot_access_token" => token,
        "access" => token,
        "copilot_expires_at" => expires_at.positive? ? Time.at(expires_at).utc.iso8601 : nil
      }.compact
    end

    def load_auth
      return nil unless File.exist?(@auth_path)

      JSON.parse(File.read(@auth_path))
    rescue JSON::ParserError
      nil
    end

    def request_device_code
      response = post_form(DEVICE_CODE_URL,
        client_id: client_id,
        scope: scope)
      parse_successful_json(response, "GitHub OAuth device code")
    end

    def poll_for_token(device_code:, interval:, timeout_seconds:)
      deadline = Time.now + timeout_seconds.to_i
      loop do
        response = post_form(TOKEN_URL,
          client_id: client_id,
          device_code: device_code,
          grant_type: "urn:ietf:params:oauth:grant-type:device_code")
        data = parse_json(response, "GitHub OAuth token poll")
        return data if response.is_a?(Net::HTTPSuccess) && data["access_token"].to_s != ""

        case data["error"].to_s
        when "authorization_pending"
          # keep polling
        when "slow_down"
          interval += 5
        when "expired_token"
          raise "GitHub OAuth device code expired"
        else
          raise "GitHub OAuth token poll failed: #{data["error_description"] || data["error"] || response.body}"
        end

        raise "GitHub OAuth login timed out" if Time.now >= deadline

        sleep interval
      end
    end

    def post_form(uri, params)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request["Accept"] = "application/json"
      request.body = URI.encode_www_form(params)

      COPILOT_HEADERS.each { |key, value| request[key] ||= value }
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    end

    def get_json(uri, headers = {})
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      COPILOT_HEADERS.merge(headers).each { |key, value| request[key] = value }

      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    end

    def parse_successful_json(response, label)
      data = parse_json(response, label)
      return data if response.is_a?(Net::HTTPSuccess) && data["error"].to_s.empty?

      raise "#{label} failed: #{data["error_description"] || data["error"] || response.body}"
    end

    def parse_json(response, label)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      raise "#{label} returned invalid JSON: #{e.message}"
    end

    def client_id
      value = ENV["GITHUB_OAUTH_CLIENT_ID"].to_s.strip
      return value unless value.empty?

      value = ConfigFiles.config_value(load_config, "github_oauth_client_id")
      return value unless value.to_s.empty?

      DEFAULT_CLIENT_ID
    end

    def scope
      ENV["GITHUB_OAUTH_SCOPE"].to_s.strip.empty? ? ConfigFiles.config_value(load_config, "github_oauth_scope") || DEFAULT_SCOPE : ENV["GITHUB_OAUTH_SCOPE"].to_s.strip
    end

    def load_config
      ConfigFiles.read_config(@config_path)
    end

    def expires_at_for(tokens)
      copilot_expires_at = tokens["copilot_expires_at"] || tokens[:copilot_expires_at]
      return copilot_expires_at if copilot_expires_at

      expires_in = tokens["expires_in"] || tokens[:expires_in]
      return nil unless expires_in.to_i.positive?

      (Time.now.utc + expires_in.to_i).iso8601
    end

    def token_expired?(auth)
      expires_at = auth&.fetch("expires_at", nil)
      return false unless expires_at

      Time.parse(expires_at) <= Time.now.utc + 60
    rescue ArgumentError
      false
    end

    def positive_integer(value)
      integer = value.to_i
      integer.positive? ? integer : nil
    end
  end
end
