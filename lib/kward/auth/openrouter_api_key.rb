require_relative "../config_files"
require_relative "openai_oauth"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Config helper for storing and removing OpenRouter API keys.
  class OpenRouterAPIKey
    attr_reader :config_path

    def initialize(config_path: OpenAIOAuth.default_config_path)
      @config_path = File.expand_path(config_path)
    end

    def api_key
      ENV["OPENROUTER_API_KEY"].to_s.empty? ? ConfigFiles.config_value(config, "openrouter_api_key") : ENV["OPENROUTER_API_KEY"]
    end

    def configured?
      !api_key.to_s.empty?
    end

    def login(prompt:)
      api_key = prompt.ask("OpenRouter API key:").to_s.strip
      raise "OpenRouter API key must be a non-empty string" if api_key.empty?

      ConfigFiles.update_config({ "openrouter_api_key" => api_key }, @config_path)
      @config_path
    end

    def logout
      ConfigFiles.delete_config_key("openrouter_api_key", @config_path)
    end

    private

    def config
      ConfigFiles.read_config(@config_path)
    rescue StandardError
      {}
    end
  end
end
