require "json"
require "net/http"
require "time"
require "uri"
require_relative "../config_files"
require_relative "../http"
require_relative "../private_file"
require_relative "provider_catalog"

# Namespace for Kward model catalogs.
module Kward
  # Fetches, normalizes, and caches provider model lists without storing secrets.
  class ModelCatalog
    VERSION = 1
    MODEL_URLS = {
      "anthropic" => "https://api.anthropic.com/v1/models",
      "cerebras" => "https://api.cerebras.ai/v1/models",
      "deepseek" => "https://api.deepseek.com/models",
      "fireworks" => "https://api.fireworks.ai/inference/v1/models",
      "gemini" => "https://generativelanguage.googleapis.com/v1beta/models",
      "groq" => "https://api.groq.com/openai/v1/models",
      "mistral" => "https://api.mistral.ai/v1/models",
      "nvidia" => "https://integrate.api.nvidia.com/v1/models",
      "openai" => "https://api.openai.com/v1/models",
      "together" => "https://api.together.xyz/v1/models",
      "xai" => "https://api.x.ai/v1/models"
    }.freeze

    attr_reader :path

    def initialize(provider_id:, api_key:, path: nil, requester: nil)
      @provider = ProviderCatalog.fetch(provider_id)
      @api_key = api_key.to_s
      @path = File.expand_path(path || ConfigFiles.model_catalog_cache_path(@provider.id))
      @requester = requester
    end

    def refresh
      raise "No #{@provider.name} API key found" if @api_key.empty?
      raise "#{@provider.name} does not support automatic model discovery" unless MODEL_URLS.key?(@provider.id)

      data = cache_data(normalize(response_body))
      PrivateFile.write_json(path, data)
      data.fetch("models")
    end

    def models
      Array(read&.fetch("models", []))
    end

    def read
      return nil unless File.exist?(path)

      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash) && data["version"] == VERSION && data["provider"] == @provider.id

      data
    rescue JSON::ParserError
      nil
    end

    private

    def response_body
      return @requester.call(url, headers) if @requester

      response = Net::HTTP.start(url.hostname, url.port, use_ssl: true) do |http|
        http.request(Http.apply_user_agent(Net::HTTP::Get.new(url)).tap do |request|
          headers.each { |name, value| request[name] = value }
        end)
      end
      raise "#{@provider.name} model refresh failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def url
      base = MODEL_URLS.fetch(@provider.id)
      return URI("#{base}?key=#{URI.encode_www_form_component(@api_key)}") if @provider.id == "gemini"

      URI(base)
    end

    def headers
      return { "x-api-key" => @api_key, "anthropic-version" => "2023-06-01" } if @provider.id == "anthropic"
      return {} if @provider.id == "gemini"

      { "Authorization" => "Bearer #{@api_key}", "Accept" => "application/json" }
    end

    def normalize(body)
      payload = JSON.parse(body.to_s)
      entries = payload["data"] || payload["models"] || []
      Array(entries).filter_map { |entry| normalize_entry(entry) }.sort_by { |entry| entry["id"] }
    rescue JSON::ParserError
      raise "#{@provider.name} model refresh returned invalid JSON"
    end

    def normalize_entry(entry)
      return unless entry.is_a?(Hash)

      id = (entry["id"] || entry["name"]).to_s.delete_prefix("models/")
      return if id.empty?

      {
        "provider" => @provider.id,
        "id" => id,
        "name" => entry["display_name"] || entry["displayName"] || entry["name"] || id,
        "contextWindow" => entry["context_window"] || entry["context_length"] || entry["inputTokenLimit"],
        "supportedParameters" => Array(entry["supported_parameters"] || entry["supportedGenerationMethods"])
      }.compact
    end

    def cache_data(models)
      {
        "version" => VERSION,
        "provider" => @provider.id,
        "refreshed_at" => Time.now.utc.iso8601,
        "models" => models
      }
    end
  end
end
