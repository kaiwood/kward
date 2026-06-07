require_relative "config_files"

module Kward
  module ModelInfo
    DEFAULT_OPENAI_MODEL = "gpt-5.5"
    DEFAULT_OPENROUTER_MODEL = "openai/gpt-5.5"
    DEFAULT_REASONING_EFFORT = "medium"
    OPENAI_MODEL_CHOICES = %w[gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex-spark].freeze
    OPENROUTER_MODEL_CHOICES = OPENAI_MODEL_CHOICES.map { |model| "openai/#{model}" }.freeze
    REASONING_EFFORT_CHOICES = [
      ["low", "Low"],
      ["medium", "Medium"],
      ["high", "High"],
      ["xhigh", "Extra High"]
    ].freeze

    IMAGE_UNSUPPORTED_MODELS = [
      /(?:\A|\/)gpt-5\.3-codex-spark\z/
    ].freeze

    OPENAI_CONTEXT_WINDOWS = [
      [/\Agpt-5\.5/, 400_000],
      [/\Agpt-5-codex/, 400_000],
      [/\Agpt-5\.3-codex-spark/, 128_000],
      [/\Agpt-5\.3-codex/, 400_000],
      [/\Agpt-5\.2-codex/, 400_000],
      [/\Agpt-5/, 400_000],
      [/\Agpt-4\.1/, 1_047_576],
      [/\Agpt-4o/, 128_000],
      [/\Ao3/, 200_000],
      [/\Ao4/, 200_000],
      [/\Agpt-4/, 128_000],
      [/\Agpt-3\.5-turbo/, 16_385]
    ].freeze

    module_function

    def model_for(provider, config:, override_model: nil, env: ENV)
      return override_model if override_model

      if provider == "OpenRouter"
        env["OPENROUTER_MODEL"] || ConfigFiles.config_value(config, "openrouter_model", "model") || DEFAULT_OPENROUTER_MODEL
      else
        env["OPENAI_MODEL"] || ConfigFiles.config_value(config, "openai_model", "model") || DEFAULT_OPENAI_MODEL
      end
    end

    def reasoning_effort(config:, env: ENV)
      env["OPENAI_REASONING_EFFORT"] || ConfigFiles.config_value(config, "openai_reasoning_effort", "reasoning_effort", "thinking_level") || DEFAULT_REASONING_EFFORT
    end

    def config_key_for_provider(provider)
      provider.to_s == "OpenRouter" ? "openrouter_model" : "openai_model"
    end

    def context_window(provider, id)
      return nil unless provider == "Codex"

      match = OPENAI_CONTEXT_WINDOWS.find { |pattern, _window| id.to_s.match?(pattern) }
      match&.last
    end

    def supports_images?(_provider, id)
      IMAGE_UNSUPPORTED_MODELS.none? { |pattern| id.to_s.match?(pattern) }
    end

    def normalize(model, current_provider: nil, current_model: nil, current_reasoning_effort: nil)
      model = stringify_keys(model || {})
      provider = model["provider"]
      id = model["id"] || model["model"]
      reasoning = boolean_value(model["reasoning"], default: provider == "Codex")
      reasoning_effort = model["reasoningEffort"] || model["reasoning_effort"] || (current_reasoning_effort if reasoning)
      {
        provider: provider,
        id: id,
        name: model["name"] || id,
        model: model["model"] || id,
        reasoning: reasoning,
        reasoningEffort: reasoning_effort,
        contextWindow: model["contextWindow"] || model["context_window"] || context_window(provider, id),
        current: boolean_value(model["current"], default: provider == current_provider && id == current_model)
      }.compact
    end

    def boolean_value(value, default: false)
      return default if value.nil?
      return value if value == true || value == false

      value.to_s == "true"
    end

    def stringify_keys(value)
      value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
    end
  end
end
