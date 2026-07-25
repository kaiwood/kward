require_relative "../auth/openai_oauth"
require_relative "../auth/api_key_store"
require_relative "../config_files"
require_relative "../model/model_info"
require_relative "../model/provider_catalog"
require_relative "../model/azure_openai_config"
require_relative "redactor"

# Namespace for the Kward CLI agent runtime.
module Kward
  # JSON-RPC backend namespace used by UI clients.
  module RPC
    # RPC configuration manager for reading and updating user config.
    class ConfigManager
      def initialize(config_path: OpenAIOAuth.default_config_path, api_key_store: nil)
        @config_path = File.expand_path(config_path)
        @api_key_store = api_key_store || APIKeyStore.new(path: File.join(File.dirname(@config_path), "api_keys.json"), config_path: @config_path)
      end

      attr_reader :config_path

      def read(redacted: true)
        config = load_config
        redacted ? Redactor.redact(config) : config
      end

      def update(values)
        reject_provider_api_keys!(values)
        Redactor.redact(ConfigFiles.update_config(values, @config_path))
      end

      def set_model(model, provider: nil)
        model = model.to_s.strip
        raise "Model must be a non-empty string" if model.empty?

        update(ModelInfo.config_values_for_selection(provider, model))
      end

      def set_reasoning_effort(effort, provider: nil)
        effort = effort.to_s.strip
        raise "Reasoning effort must be a non-empty string" if effort.empty?

        update(ModelInfo.reasoning_config_key_for_provider(provider) => effort)
      end

      def set_api_key(provider_id, api_key)
        provider = ProviderCatalog.fetch(provider_id)
        raise "#{provider.name} does not accept an API key" unless provider.api_key?

        @api_key_store.store(provider.id, api_key)
      end

      def api_key_status(provider_id)
        provider = ProviderCatalog.fetch(provider_id)
        configured = @api_key_store.configured?(provider.id)
        stored = @api_key_store.stored?(provider.id)
        {
          configured: configured,
          stored: stored,
          source: configured ? (environment_api_key?(provider) ? "environment" : "stored") : nil,
          canLogout: stored
        }.compact
      end

      def delete_api_key(provider_id)
        @api_key_store.delete(provider_id)
      end

      def configure_azure_openai(values)
        setup = AzureOpenAIConfig.new(
          endpoint: values["endpoint"] || values[:endpoint],
          deployment: values["deployment"] || values[:deployment],
          api_version: values["apiVersion"] || values[:apiVersion] || values["api_version"] || values[:api_version]
        )
        update(setup.to_config)
      end

      def delete_key(key)
        ConfigFiles.delete_config_key(key, @config_path)
      end

      def workspace_guardrails_enabled?
        ConfigFiles.workspace_guardrails_enabled?(read(redacted: false))
      end

      def session_auto_resume_enabled?
        ConfigFiles.session_auto_resume_enabled?(read(redacted: false))
      end

      private

      def reject_provider_api_keys!(values)
        keys = values.respond_to?(:keys) ? values.keys.map(&:to_s) : []
        private_keys = ProviderCatalog.api_key_providers.map { |provider| "#{provider.id}_api_key" }
        return if (keys & private_keys).empty?

        raise ArgumentError, "Provider API keys must be saved with auth/loginWithApiKey"
      end

      def environment_api_key?(provider)
        provider.api_key_env.any? { |name| !ENV[name].to_s.strip.empty? }
      end

      def load_config
        ConfigFiles.read_config(@config_path)
      end
    end
  end
end
