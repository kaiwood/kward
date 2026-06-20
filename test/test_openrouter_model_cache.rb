require_relative "test_helper"

class TestOpenRouterModelCache < KwardTestCase
  class FakeHTTP
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(request)
      @requests << request
      @responses.shift
    end
  end

  def with_fake_http(responses)
    fake_http = FakeHTTP.new(responses)
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |_host, _port, **_options, &block|
      block.call(fake_http)
    end
    yield fake_http
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
  end

  def test_refresh_caches_key_scoped_text_models
    Dir.mktmpdir do |dir|
      path = File.join(dir, "openrouter_models.json")
      body = JSON.dump("data" => [
        {
          "id" => "anthropic/claude-sonnet-4.5",
          "name" => "Claude Sonnet",
          "context_length" => 200_000,
          "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["text"] },
          "supported_parameters" => ["tools"]
        },
        {
          "id" => "openai/image-only",
          "architecture" => { "input_modalities" => ["text"], "output_modalities" => ["image"] }
        }
      ])
      cache = Kward::OpenRouterModelCache.new(api_key: "sk-or-secret", path: path)

      with_fake_http([fake_net_response(200, body)]) do |http|
        data = cache.refresh

        assert_equal URI("https://openrouter.ai/api/v1/models/user"), http.requests.first.uri
        assert_equal "Bearer sk-or-secret", http.requests.first["Authorization"]
        assert_equal ["anthropic/claude-sonnet-4.5"], data.fetch("models").map { |model| model.fetch("id") }
        assert_equal "Claude Sonnet", data.fetch("models").first.fetch("name")
        assert_equal 200_000, data.fetch("models").first.fetch("contextWindow")
        refute_includes File.read(path), "sk-or-secret"
        assert_equal 0o600, File.stat(path).mode & 0o777
      end
    end
  end

  def test_refresh_rejects_missing_api_key
    cache = Kward::OpenRouterModelCache.new(api_key: "", path: "missing.json")

    error = assert_raises(RuntimeError) { cache.refresh }

    assert_includes error.message, "No OpenRouter API key"
  end
end
