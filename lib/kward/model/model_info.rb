require_relative "../config_files"

module Kward
  module ModelInfo
    DEFAULT_OPENAI_MODEL = "gpt-5.5"
    DEFAULT_OPENROUTER_MODEL = "openai/gpt-5.5"
    DEFAULT_COPILOT_MODEL = "gpt-5-mini"
    DEFAULT_REASONING_EFFORT = "medium"
    OPENAI_MODEL_CHOICES = %w[gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.3-codex-spark].freeze
    OPENROUTER_MODEL_CHOICES = OPENAI_MODEL_CHOICES.map { |model| "openai/#{model}" }.freeze
    COPILOT_MODEL_CHOICES = %w[
      gpt-5-mini
      gpt-5.3-codex
      gpt-5.4
      gpt-5.4-mini
      gpt-5.5
      claude-haiku-4.5
      claude-opus-4.5
      claude-opus-4.7
      claude-opus-4.8
      claude-sonnet-4.5
      claude-sonnet-4.6
      gemini-2.5-pro
      gemini-3-flash-preview
      gemini-3.1-pro-preview
      gemini-3.5-flash
      oswe-vscode-prime
    ].freeze
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

      case provider
      when "OpenRouter"
        env["OPENROUTER_MODEL"] || ConfigFiles.config_value(config, "openrouter_model", "model") || DEFAULT_OPENROUTER_MODEL
      when "Copilot"
        normalize_copilot_model(env["COPILOT_MODEL"] || ConfigFiles.config_value(config, "copilot_model", "model") || DEFAULT_COPILOT_MODEL)
      else
        env["OPENAI_MODEL"] || ConfigFiles.config_value(config, "openai_model", "model") || DEFAULT_OPENAI_MODEL
      end
    end

    def normalize_copilot_model(id)
      text = id.to_s.strip
      return DEFAULT_COPILOT_MODEL if text.empty?
      text = text.delete_prefix("copilot/")

      {
        "claude-haiku-4-5" => "claude-haiku-4.5",
        "claude-opus-4-5" => "claude-opus-4.5",
        "claude-opus-4-6" => "claude-opus-4.6",
        "claude-opus-4-6-fast" => "claude-opus-4.6-fast",
        "claude-opus-4-7" => "claude-opus-4.7",
        "claude-opus-4-8" => "claude-opus-4.8",
        "claude-sonnet-4-5" => "claude-sonnet-4.5",
        "claude-sonnet-4-6" => "claude-sonnet-4.6",
        "gemini-3.1-pro" => "gemini-3.1-pro-preview",
        "gemini-3-flash" => "gemini-3-flash-preview"
      }.fetch(text, text)
    end

    def reasoning_effort(config:, env: ENV, provider: nil)
      case provider.to_s
      when "OpenRouter"
        env["OPENROUTER_REASONING_EFFORT"] || ConfigFiles.config_value(config, "openrouter_reasoning_effort", "reasoning_effort", "thinking_level") || DEFAULT_REASONING_EFFORT
      when "Copilot"
        env["COPILOT_REASONING_EFFORT"] || ConfigFiles.config_value(config, "copilot_reasoning_effort", "reasoning_effort", "thinking_level") || DEFAULT_REASONING_EFFORT
      else
        env["OPENAI_REASONING_EFFORT"] || ConfigFiles.config_value(config, "openai_reasoning_effort", "reasoning_effort", "thinking_level") || DEFAULT_REASONING_EFFORT
      end
    end

    def provider_label(provider)
      case provider.to_s.downcase
      when "openrouter" then "OpenRouter"
      when "copilot" then "Copilot"
      when "codex", "openai" then "Codex"
      else provider.to_s
      end
    end

    def provider_config_value(provider)
      case provider.to_s
      when "OpenRouter" then "openrouter"
      when "Copilot" then "copilot"
      else "codex"
      end
    end

    def config_key_for_provider(provider)
      case provider.to_s
      when "OpenRouter" then "openrouter_model"
      when "Copilot" then "copilot_model"
      else "openai_model"
      end
    end

    def reasoning_config_key_for_provider(provider)
      case provider.to_s
      when "OpenRouter" then "openrouter_reasoning_effort"
      when "Copilot" then "copilot_reasoning_effort"
      else "openai_reasoning_effort"
      end
    end

    def config_provider_for_provider(provider)
      provider_config_value(provider)
    end

    def config_values_for_selection(provider, model)
      {
        config_key_for_provider(provider) => model,
        "provider" => config_provider_for_provider(provider)
      }
    end

    def context_window(provider, id)
      return nil unless provider == "Codex"

      match = OPENAI_CONTEXT_WINDOWS.find { |pattern, _window| id.to_s.match?(pattern) }
      match&.last
    end

    def supports_images?(_provider, id)
      IMAGE_UNSUPPORTED_MODELS.none? { |pattern| id.to_s.match?(pattern) }
    end

    def reasoning_supported?(provider, id)
      provider == "Codex" || provider == "OpenRouter" || (provider == "Copilot" && id.to_s.match?(/\Agpt-5(?:\.|-|\z)/))
    end

    def normalize(model, current_provider: nil, current_model: nil, current_reasoning_effort: nil)
      model = stringify_keys(model || {})
      provider = model["provider"]
      id = model["id"] || model["model"]
      reasoning = boolean_value(model["reasoning"], default: reasoning_supported?(provider, id))
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
