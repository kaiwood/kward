require_relative "test_helper"

class TestModelInfo < KwardTestCase
  def test_context_window_uses_known_codex_model_patterns
    cases = {
      "gpt-5.5" => 1_050_000,
      "gpt-5.5-latest" => 1_050_000,
      "gpt-5.4" => 1_050_000,
      "gpt-5.4-mini" => 400_000,
      "gpt-5-mini" => 400_000,
      "gpt-5-codex" => 400_000,
      "gpt-5.3-codex-spark" => 128_000,
      "gpt-5.3-codex" => 400_000,
      "gpt-5.2-codex" => 400_000,
      "gpt-5" => 400_000,
      "gpt-4.1" => 1_047_576,
      "gpt-4o" => 128_000,
      "o3" => 200_000,
      "o4" => 200_000,
      "gpt-4" => 128_000,
      "gpt-3.5-turbo" => 16_385
    }

    cases.each do |model, context_window|
      assert_equal context_window, Kward::ModelInfo.context_window("Codex", model), model
    end
  end

  def test_context_window_uses_provider_model_patterns
    assert_equal 1_050_000, Kward::ModelInfo.context_window("OpenRouter", "openai/gpt-5.5")
    assert_equal 1_000_000, Kward::ModelInfo.context_window("OpenRouter", "anthropic/claude-opus-4.8")
    assert_equal 1_048_576, Kward::ModelInfo.context_window("OpenRouter", "google/gemini-3.1-pro-preview")
    assert_equal 1_000_000, Kward::ModelInfo.context_window("Copilot", "claude-sonnet-4.6")
    assert_equal 1_048_576, Kward::ModelInfo.context_window("Copilot", "gemini-3.5-flash")
    assert_nil Kward::ModelInfo.context_window("OpenRouter", "unknown/model")
  end

  def test_supports_images_excludes_codex_spark
    refute Kward::ModelInfo.supports_images?("Codex", "gpt-5.3-codex-spark")
    refute Kward::ModelInfo.supports_images?("OpenRouter", "openai/gpt-5.3-codex-spark")
    assert Kward::ModelInfo.supports_images?("Codex", "gpt-5.5")
  end

  def test_provider_config_keys_are_provider_specific_and_case_insensitive
    assert_equal "openai_model", Kward::ModelInfo.config_key_for_provider("Codex")
    assert_equal "openrouter_model", Kward::ModelInfo.config_key_for_provider("OpenRouter")
    assert_equal "openrouter_model", Kward::ModelInfo.config_key_for_provider("openrouter")
    assert_equal "copilot_model", Kward::ModelInfo.config_key_for_provider("Copilot")
    assert_equal "copilot_model", Kward::ModelInfo.config_key_for_provider("copilot")
    assert_equal "anthropic_model", Kward::ModelInfo.config_key_for_provider("Anthropic")
    assert_equal "anthropic_model", Kward::ModelInfo.config_key_for_provider("claude")

    assert_equal "openai_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("Codex")
    assert_equal "openrouter_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("OpenRouter")
    assert_equal "openrouter_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("openrouter")
    assert_equal "copilot_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("Copilot")
    assert_equal "copilot_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("copilot")
    assert_equal "anthropic_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("Anthropic")
    assert_equal "anthropic_reasoning_effort", Kward::ModelInfo.reasoning_config_key_for_provider("claude")
  end

  def test_anthropic_model_and_provider_metadata
    assert_equal "Anthropic", Kward::ModelInfo.provider_label("claude")
    assert_equal "anthropic", Kward::ModelInfo.provider_config_value("Anthropic")
    assert_equal "claude-sonnet-4-6", Kward::ModelInfo.model_for("Anthropic", config: {}, env: {})
    assert_equal "claude-opus-4-5", Kward::ModelInfo.model_for("Anthropic", config: { "anthropic_model" => "claude-opus-4.5" }, env: {})
    assert_equal "claude-opus-4-8", Kward::ModelInfo.normalize_anthropic_model("claude-opus-4.8")
    assert_equal 1_000_000, Kward::ModelInfo.context_window("Anthropic", "claude-sonnet-4-6")
    assert_equal 1_000_000, Kward::ModelInfo.context_window("Anthropic", "claude-opus-4-8")
    assert_equal 200_000, Kward::ModelInfo.context_window("Anthropic", "claude-sonnet-4-5")
    assert_equal 200_000, Kward::ModelInfo.context_window("Anthropic", "claude-haiku-4-5")
    refute Kward::ModelInfo.reasoning_supported?("Anthropic", "claude-sonnet-4-5")
    assert Kward::ModelInfo.reasoning_supported?("Anthropic", "claude-sonnet-4-6")
  end

  def test_reasoning_effort_choices_are_model_specific
    assert_equal %w[none low medium high xhigh], Kward::ModelInfo.reasoning_effort_choices("Codex", "gpt-5.5").map(&:first)
    assert_equal %w[low medium high xhigh], Kward::ModelInfo.reasoning_effort_choices("Codex", "gpt-5.3-codex").map(&:first)
    assert_equal %w[low medium high xhigh max], Kward::ModelInfo.reasoning_effort_choices("Anthropic", "claude-opus-4-8").map(&:first)
    assert_equal %w[low medium high max], Kward::ModelInfo.reasoning_effort_choices("Anthropic", "claude-sonnet-4-6").map(&:first)
    assert_equal %w[low medium high], Kward::ModelInfo.reasoning_effort_choices("Anthropic", "claude-opus-4-5").map(&:first)
    assert_empty Kward::ModelInfo.reasoning_effort_choices("Anthropic", "claude-haiku-4-5")
    assert_equal %w[none low medium high xhigh], Kward::ModelInfo.reasoning_effort_choices("Copilot", "gpt-5-mini").map(&:first)
  end

  def test_copilot_reasoning_effort_uses_copilot_config_and_env
    config = {
      "openai_reasoning_effort" => "low",
      "copilot_reasoning_effort" => "high"
    }

    assert_equal "high", Kward::ModelInfo.reasoning_effort(config: config, provider: "Copilot", env: {})
    assert_equal "xhigh", Kward::ModelInfo.reasoning_effort(config: config, provider: "Copilot", env: { "COPILOT_REASONING_EFFORT" => "xhigh" })
  end
end
