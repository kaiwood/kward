require "base64"
require "json"
require "net/http"
require "uri"
require_relative "../cancellation"
require_relative "../http"

module Kward
  # Codex subscription transport, separate from the chat Responses stream.
  class CodexImages
    URL = URI("https://chatgpt.com/backend-api/codex/images/generations")
    MAX_IMAGE_BYTES = 20 * 1024 * 1024
    MAX_RESPONSE_BYTES = (MAX_IMAGE_BYTES + 2) / 3 * 4 + 65_536
    PNG_HEADER = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".b.freeze
    Error = Class.new(StandardError)

    def self.generate(prompt, token:, account_id:, turn_id:, cancellation: nil)
      request = Http.apply_user_agent(Net::HTTP::Post.new(URL))
      request["Authorization"] = "Bearer #{token}"
      request["ChatGPT-Account-Id"] = account_id unless account_id.to_s.empty?
      request["x-codex-image-turn-id"] = turn_id unless turn_id.to_s.empty?
      request["originator"] = "kward"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(prompt: prompt, model: "gpt-image-2", background: "opaque", quality: "auto", size: "auto")

      body = +""
      cancellation&.raise_if_cancelled!
      Net::HTTP.start(URL.hostname, URL.port, use_ssl: true, open_timeout: 10, read_timeout: 180) do |http|
        http.max_retries = 0
        cancellation&.on_cancel { http.finish if http.started? }
        cancellation&.raise_if_cancelled!
        http.request(request) do |response|
          raise Error, error_message(response.code.to_i) unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            cancellation&.raise_if_cancelled!
            raise Error, "Codex image exceeds the preview size limit." if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

            body << chunk
          end
        end
      end
      cancellation&.raise_if_cancelled!
      decode(body)
    rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
      cancellation&.raise_if_cancelled!
      raise Error, "The connection to Codex image generation was interrupted; it was not retried."
    end

    def self.decode(body)
      result = JSON.parse(body)
      data = result.is_a?(Hash) ? result["data"] : nil
      first = data.first if data.is_a?(Array)
      encoded = first["b64_json"] if first.is_a?(Hash)
      raise Error, "Codex did not return an image." unless encoded.is_a?(String)

      bytes = Base64.strict_decode64(encoded)
      raise Error, "Codex returned an invalid or oversized PNG." unless valid_png?(bytes)

      bytes
    rescue JSON::ParserError, ArgumentError
      raise Error, "Codex returned an invalid image response."
    end

    def self.valid_png?(bytes)
      return false unless bytes.is_a?(String) && bytes.bytesize.between?(45, MAX_IMAGE_BYTES) && bytes.b.start_with?(PNG_HEADER)

      width, height = bytes.byteslice(16, 8).unpack("NN")
      width.between?(1, 8192) && height.between?(1, 8192) && bytes.end_with?("\x00\x00\x00\x00IEND\xaeB`\x82".b)
    end

    def self.error_message(status)
      case status
      when 401 then "Codex sign-in expired; sign in again to generate an image."
      when 403, 404 then "Image generation is not available for this Codex account."
      when 429 then "Codex image generation is rate-limited or the account has reached its usage limit."
      else "Codex could not generate an image (HTTP #{status})."
      end
    end
    private_class_method :decode, :error_message
  end
end
