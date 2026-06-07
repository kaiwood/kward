require_relative "test_helper"

class TestModelInfo < KwardTestCase
  def test_context_window_uses_known_codex_model_patterns
    cases = {
      "gpt-5.5" => 400_000,
      "gpt-5.5-latest" => 400_000,
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

  def test_context_window_only_applies_to_codex_provider
    assert_nil Kward::ModelInfo.context_window("OpenRouter", "gpt-5.5")
  end

  def test_supports_images_excludes_codex_spark
    refute Kward::ModelInfo.supports_images?("Codex", "gpt-5.3-codex-spark")
    refute Kward::ModelInfo.supports_images?("OpenRouter", "openai/gpt-5.3-codex-spark")
    assert Kward::ModelInfo.supports_images?("Codex", "gpt-5.5")
  end
end
