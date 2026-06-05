require_relative "../config_files"
require_relative "../model_info"
require_relative "../openai_oauth"
require_relative "redactor"

module Kward
  module RPC
    class ConfigManager
      def initialize(config_path: OpenAIOAuth.default_config_path)
        @config_path = File.expand_path(config_path)
      end

      attr_reader :config_path

      def read(redacted: true)
        config = load_config
        redacted ? Redactor.redact(config) : config
      end

      def update(values)
        Redactor.redact(ConfigFiles.update_config(values, @config_path))
      end

      def set_model(model, provider: nil)
        model = model.to_s.strip
        raise "Model must be a non-empty string" if model.empty?

        update(ModelInfo.config_key_for_provider(provider) => model)
      end

      def set_reasoning_effort(effort)
        effort = effort.to_s.strip
        raise "Reasoning effort must be a non-empty string" if effort.empty?

        update("openai_reasoning_effort" => effort)
      end

      def set_api_key(provider_id, api_key)
        provider_id = provider_id.to_s
        api_key = api_key.to_s.strip
        raise "API key must be a non-empty string" if api_key.empty?
        raise "Unsupported API key provider: #{provider_id}" unless provider_id == "openrouter"

        update("openrouter_api_key" => api_key)
      end

      def delete_key(key)
        ConfigFiles.delete_config_key(key, @config_path)
      end

      private

      def load_config
        ConfigFiles.read_config(@config_path)
      end
    end
  end
end
