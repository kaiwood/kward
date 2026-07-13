require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "time"
require "uri"
require_relative "../http"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Shared browser OAuth mechanics used by provider-specific credential flows.
  module OAuthHelpers
    private

    def generate_pkce
      verifier = random_urlsafe(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      { verifier: verifier, challenge: challenge }
    end

    def random_urlsafe(bytes)
      Base64.urlsafe_encode64(SecureRandom.random_bytes(bytes), padding: false)
    end

    def oauth_callback_server(port_env:, default_port:)
      TCPServer.new("localhost", Integer(ENV.fetch(port_env, default_port)))
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
      elsif params["state"].to_s != expected_state.to_s
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

    def post_json(uri, params = nil, headers: {}, **keyword_params)
      params = (params || {}).merge(keyword_params)
      request = Http.apply_user_agent(Net::HTTP::Post.new(uri))
      request["Content-Type"] = "application/json"
      headers.each { |key, value| request[key] = value }
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
