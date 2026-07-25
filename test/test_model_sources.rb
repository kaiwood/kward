require_relative "test_helper"
require_relative "../lib/kward/model/sources"

class TestModelSources < KwardTestCase
  FakeCatalog = Struct.new(:cached, :fresh, :error) do
    def models
      cached
    end

    def refresh
      raise error if error

      fresh
    end
  end

  def test_models_combine_cached_and_curated_entries
    sources = Kward::ModelSources.new(
      provider_id: "anthropic",
      catalog: FakeCatalog.new([{ "id" => "claude-sonnet-5", "name" => "Live name" }], [])
    )

    models = sources.models

    assert_equal %w[claude-haiku-4-5 claude-opus-4-8 claude-sonnet-5], models.map { |model| model["id"] }
    assert_equal "cached", models.last["source"]
    assert_equal "Live name", models.last["name"]
  end

  def test_refresh_falls_back_to_cached_models_when_live_request_fails
    sources = Kward::ModelSources.new(
      provider_id: "deepseek",
      catalog: FakeCatalog.new([{ "id" => "account-model" }], [], RuntimeError.new("unavailable"))
    )

    models = sources.refresh

    assert_equal %w[account-model deepseek-chat deepseek-reasoner], models.map { |model| model["id"] }
    assert_equal "cached", models.first["source"]
  end

  def test_manual_model_requires_a_value
    sources = Kward::ModelSources.new(provider_id: "groq", catalog: FakeCatalog.new([], []))

    assert_equal "manual-id", sources.manual(" manual-id ")["id"]
    assert_raises(ArgumentError) { sources.manual(" ") }
  end
end
