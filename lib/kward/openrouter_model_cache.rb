require "digest"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "config_files"
require_relative "private_file"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Fetches and stores the OpenRouter model list available to the configured API key.
  class OpenRouterModelCache
    MODELS_URL = URI("https://openrouter.ai/api/v1/models/user")
    VERSION = 1

    attr_reader :path

    def initialize(api_key:, path: ConfigFiles.openrouter_models_cache_path)
      @api_key = api_key.to_s
      @path = File.expand_path(path)
    end

    def self.model_entry?(entry)
      return false unless entry.is_a?(Hash)

      architecture = entry["architecture"].is_a?(Hash) ? entry["architecture"] : {}
      input_modalities = Array(architecture["input_modalities"]).map(&:to_s)
      output_modalities = Array(architecture["output_modalities"]).map(&:to_s)
      input_modalities.include?("text") && output_modalities.include?("text")
    end

    def refresh
      raise "No OpenRouter API key found. Set OPENROUTER_API_KEY or add openrouter_api_key to your Kward config." if @api_key.empty?

      response = Net::HTTP.start(MODELS_URL.hostname, MODELS_URL.port, use_ssl: true) do |http|
        http.request(refresh_request)
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise "OpenRouter model refresh failed: #{response.code} #{redact(response.body)}"
      end

      entries = model_entries(response.body)
      models = entries.select { |entry| self.class.model_entry?(entry) }.map { |entry| normalize_model(entry) }.uniq { |model| model["id"] }.sort_by { |model| model["id"] }
      data = cache_data(models)
      PrivateFile.write_json(@path, data)
      data
    end

    def read
      return nil unless File.exist?(@path)

      data = JSON.parse(File.read(@path))
      return nil unless data.is_a?(Hash) && data["version"] == VERSION

      data
    rescue JSON::ParserError
      nil
    end

    def models
      Array(read&.fetch("models", []))
    end

    def matching_key?
      data = read
      return false unless data

      data["api_key_sha256"] == api_key_sha256
    end

    private

    def refresh_request
      Net::HTTP::Get.new(MODELS_URL).tap do |request|
        request["Authorization"] = "Bearer #{@api_key}"
        request["Accept"] = "application/json"
      end
    end

    def model_entries(body)
      data = JSON.parse(body.to_s)
      entries = data.is_a?(Hash) ? data["data"] || [] : data
      Array(entries).select { |entry| entry.is_a?(Hash) }
    rescue JSON::ParserError
      raise "OpenRouter model refresh returned invalid JSON"
    end

    def normalize_model(entry)
      {
        "provider" => "OpenRouter",
        "id" => entry.fetch("id").to_s,
        "name" => entry["name"].to_s.empty? ? entry.fetch("id").to_s : entry["name"].to_s,
        "contextWindow" => entry["context_length"],
        "supportedParameters" => Array(entry["supported_parameters"]).map(&:to_s)
      }.compact
    end

    def cache_data(models)
      {
        "version" => VERSION,
        "refreshed_at" => Time.now.utc.iso8601,
        "source" => MODELS_URL.to_s,
        "filter" => {
          "input_modalities" => ["text"],
          "output_modalities" => ["text"]
        },
        "api_key_sha256" => api_key_sha256,
        "models" => models
      }
    end

    def api_key_sha256
      Digest::SHA256.hexdigest(@api_key)
    end

    def redact(text)
      text.to_s.gsub(@api_key, "[REDACTED]")
    end
  end
end
