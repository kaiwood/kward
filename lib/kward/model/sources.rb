require_relative "catalog"
require_relative "model_info"
require_relative "provider_catalog"

# Namespace for Kward model catalogs.
module Kward
  # Combines live, cached, and curated provider models for selection UIs.
  class ModelSources
    CURATED_MODELS = {
      "anthropic" => %w[claude-sonnet-5 claude-opus-4-8 claude-haiku-4-5],
      "azure_openai" => [],
      "cerebras" => [],
      "deepseek" => %w[deepseek-chat deepseek-reasoner],
      "fireworks" => [],
      "gemini" => %w[gemini-2.5-pro gemini-2.5-flash],
      "groq" => [],
      "mistral" => %w[mistral-large-latest],
      "nvidia" => [],
      "openai" => ModelInfo::OPENAI_MODEL_CHOICES,
      "openrouter" => [],
      "together" => [],
      "xai" => %w[grok-3 grok-3-mini],
      "copilot" => ModelInfo::COPILOT_MODEL_CHOICES
    }.freeze

    def initialize(provider_id:, api_key: nil, catalog: nil)
      @provider = ProviderCatalog.fetch(provider_id)
      @catalog = catalog || ModelCatalog.new(provider_id: @provider.id, api_key: api_key)
    end

    def models
      merge(cached_models, curated_models)
    end

    def refresh
      merge(live_models, curated_models)
    rescue StandardError
      models
    end

    def manual(id)
      value = id.to_s.strip
      raise ArgumentError, "Model ID must be a non-empty string" if value.empty?

      { "provider" => @provider.id, "id" => value, "name" => value, "source" => "manual" }
    end

    private

    def live_models
      @catalog.refresh.map { |model| model.merge("source" => "live") }
    end

    def cached_models
      @catalog.models.map { |model| model.merge("source" => "cached") }
    end

    def curated_models
      CURATED_MODELS.fetch(@provider.id, []).map do |id|
        { "provider" => @provider.id, "id" => id, "name" => id, "source" => "curated" }
      end
    end

    def merge(*groups)
      groups.flatten.each_with_object({}) do |model, result|
        result[model.fetch("id")] ||= model
      end.values.sort_by { |model| model.fetch("id") }
    end
  end
end
