require "json"
require_relative "../config_files"
require_relative "../private_file"
require_relative "../model/provider_catalog"

# Namespace for Kward credential storage.
module Kward
  # Stores API keys outside the non-secret Kward configuration file.
  class APIKeyStore
    def initialize(path: APIKeyStore.default_path, config_path: ConfigFiles.config_path, env: ENV)
      @path = File.expand_path(path)
      @config_path = File.expand_path(config_path)
      @env = env
    end

    attr_reader :path

    def self.default_path
      File.join(ConfigFiles.config_dir, "api_keys.json")
    end

    def fetch(provider_id)
      provider = ProviderCatalog.fetch(provider_id)
      environment_key(provider) || stored_key(provider.id)
    end

    def configured?(provider_id)
      !fetch(provider_id).to_s.empty?
    end

    def store(provider_id, api_key)
      provider = ProviderCatalog.fetch(provider_id)
      raise ArgumentError, "#{provider.name} does not accept an API key" unless provider.api_key?

      api_key = api_key.to_s.strip
      raise ArgumentError, "API key must be a non-empty string" if api_key.empty?

      keys = stored_keys
      keys[provider.id] = api_key
      write_keys(keys)
      path
    end

    def delete(provider_id)
      provider = ProviderCatalog.fetch(provider_id)
      keys = stored_keys
      return false unless keys.delete(provider.id)

      write_keys(keys)
      true
    end

    def stored?(provider_id)
      !stored_key(provider_id).to_s.empty?
    end

    def migrate_openrouter_config_key!
      return false if stored?("openrouter")

      config = ConfigFiles.read_config(@config_path)
      key = config["openrouter_api_key"].to_s.strip
      return false if key.empty?

      store("openrouter", key)
      ConfigFiles.delete_config_key("openrouter_api_key", @config_path)
      true
    end

    private

    def environment_key(provider)
      provider.api_key_env.map { |name| @env[name].to_s.strip }.find { |key| !key.empty? }
    end

    def stored_key(provider_id)
      stored_keys[provider_id.to_s]
    end

    def stored_keys
      return {} unless File.exist?(path)

      data = JSON.parse(File.read(path))
      raise "Invalid Kward API key file: #{path}" unless data.is_a?(Hash)

      data.transform_keys(&:to_s).transform_values(&:to_s)
    rescue JSON::ParserError => e
      raise "Invalid Kward API key file: #{path}: #{e.message}"
    end

    def write_keys(keys)
      PrivateFile.write_json(path, keys)
    end
  end
end
