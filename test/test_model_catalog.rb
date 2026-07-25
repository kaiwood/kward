require_relative "test_helper"
require_relative "../lib/kward/model/catalog"

class TestModelCatalog < KwardTestCase
  def test_refresh_normalizes_and_caches_openai_compatible_models
    Dir.mktmpdir do |directory|
      requested_headers = nil
      catalog = Kward::ModelCatalog.new(
        provider_id: "groq",
        api_key: "secret-key",
        path: File.join(directory, "models.json"),
        requester: lambda { |_url, headers|
          requested_headers = headers
          JSON.dump("data" => [{ "id" => "model-b" }, { "id" => "model-a", "context_window" => 32_768 }])
        }
      )

      models = catalog.refresh

      assert_equal ["model-a", "model-b"], models.map { |model| model["id"] }
      assert_equal 32_768, models.first["contextWindow"]
      assert_equal "Bearer secret-key", requested_headers["Authorization"]
      assert_equal models, catalog.models
      refute_includes File.read(catalog.path), "secret-key"
    end
  end

  def test_refresh_uses_gemini_query_key_and_normalizes_model_names
    requested_url = nil
    catalog = Kward::ModelCatalog.new(
      provider_id: "gemini",
      api_key: "secret-key",
      path: File.join(Dir.mktmpdir, "models.json"),
      requester: lambda { |url, _headers|
        requested_url = url
        JSON.dump("models" => [{ "name" => "models/gemini-test", "displayName" => "Gemini Test", "inputTokenLimit" => 1_000 }])
      }
    )

    models = catalog.refresh

    assert_equal "gemini-test", models.first["id"]
    assert_equal "Gemini Test", models.first["name"]
    assert_equal 1_000, models.first["contextWindow"]
    assert_includes requested_url.to_s, "key=secret-key"
  end

  def test_read_ignores_invalid_cache
    path = File.join(Dir.mktmpdir, "models.json")
    File.write(path, "not json")

    assert_nil Kward::ModelCatalog.new(provider_id: "groq", api_key: "key", path: path).read
  end
end
