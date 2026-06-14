require_relative "test_helper"

class TestWebSearch < KwardTestCase
  def test_web_search_uses_duckduckgo_results
    html = '<div class="result"><a class="result__a" href="https://example.com/ruby">Ruby News</a><a class="result__snippet">Ruby release notes</a></div>'
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, html)
    )
    research = Kward::WebSearch.new(http_client: http, searxng_instances: [])

    result = research.search("queries" => ["ruby news"], "provider" => "duckduckgo")

    assert_includes result, "# Web search"
    assert_includes result, "Provider: duckduckgo"
    assert_includes result, "Ruby News"
    assert_includes result, "https://example.com/ruby"
  end

  def test_web_search_falls_back_to_searxng_json
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(429, "rate limited"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(200, JSON.dump(
        "results" => [{ "title" => "Fallback Result", "url" => "https://example.com/fallback", "content" => "search snippet" }]
      ))
    )
    research = Kward::WebSearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"], "provider" => "duckduckgo")

    assert_includes result, "Provider fallback note: DuckDuckGo search failed with HTTP 429"
    assert_includes result, "Provider: searxng"
    assert_includes result, "search snippet"
  end

  def test_web_search_uses_searxng_html_when_json_is_disabled
    html = '<article class="result"><h3><a href="https://example.com/html-page">HTML Result</a></h3><p class="content">HTML snippet</p></article>'
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(500, "nope"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(403, "json disabled"),
      ["GET", "https://searx.test/search?q=ruby"] => fake_response(200, html)
    )
    research = Kward::WebSearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"], "provider" => "duckduckgo")

    assert_includes result, "HTML Result"
    assert_includes result, "HTML snippet"
  end

  def test_web_search_returns_clear_error_when_all_providers_fail
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(500, "nope"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(403, "json disabled")
    )
    research = Kward::WebSearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"], "provider" => "duckduckgo")

    assert_includes result, "Error: web_search found no results"
    assert_includes result, "DuckDuckGo search failed with HTTP 500"
    assert_includes result, "SearXNG search failed with HTTP 403"
  end

  def test_web_search_truncates_large_output
    html = "<div class=\"result\"><a class=\"result__a\" href=\"https://example.com/large\">Large</a><a class=\"result__snippet\">#{"x" * 500}</a></div>"
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, html)
    )
    research = Kward::WebSearch.new(http_client: http, searxng_instances: [], max_output_bytes: 120)

    result = research.search("queries" => ["ruby"], "provider" => "duckduckgo")

    assert_includes result, "... truncated to 120 bytes"
  end

  def test_web_search_rejects_legacy_provider_name
    research = Kward::WebSearch.new

    result = research.search("queries" => ["ruby"], "provider" => "legacy")

    assert_equal "Error: provider must be one of: auto, exa, perplexity, gemini, duckduckgo", result
  end

  def test_web_search_uses_keyless_exa_mcp_by_default
    mcp_payload = JSON.dump(
      "result" => {
        "content" => [{ "type" => "text", "text" => "Title: Exa Result\nURL: https://example.com/exa\nText: Exa snippet\n---" }]
      }
    )
    mcp_body = "data: #{mcp_payload}\n"
    http = FakeHttpClient.new(
      ["POST_JSON", "https://mcp.exa.ai/mcp"] => fake_response(200, mcp_body)
    )
    research = Kward::WebSearch.new(http_client: http, config: {})

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Provider: exa"
    assert_includes result, "Exa Result"
    assert_includes result, "https://example.com/exa"
    assert_equal "web_search_exa", http.requests.first[:body]["params"]["name"]
  end

  def test_web_search_uses_configured_exa_api_key_without_exposing_it
    body = JSON.dump(
      "answer" => "Configured Exa answer",
      "citations" => [{ "title" => "Exa API", "url" => "https://example.com/api", "text" => "API snippet" }]
    )
    http = FakeHttpClient.new(
      ["POST_JSON", "https://api.exa.ai/answer"] => fake_response(200, body)
    )
    research = Kward::WebSearch.new(http_client: http, config: { "web_search" => { "exa_api_key" => "exa-secret" } })

    result = research.search("queries" => ["ruby"], "provider" => "exa")

    assert_includes result, "Configured Exa answer"
    assert_includes result, "Exa API"
    refute_includes result, "exa-secret"
    assert_equal "exa-secret", http.requests.first[:headers]["x-api-key"]
  end

  def test_web_search_falls_back_to_configured_perplexity_after_exa_failure
    perplexity_body = JSON.dump(
      "choices" => [{ "message" => { "content" => "Perplexity answer" } }],
      "citations" => ["https://example.com/perplexity"]
    )
    http = FakeHttpClient.new(
      ["POST_JSON", "https://mcp.exa.ai/mcp"] => fake_response(500, "nope"),
      ["POST_JSON", "https://api.perplexity.ai/chat/completions"] => fake_response(200, perplexity_body)
    )
    research = Kward::WebSearch.new(http_client: http, config: { "web_search" => { "perplexity_api_key" => "pplx-secret", "allow_model_providers" => true } })

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Provider fallback note: exa: Exa MCP failed with HTTP 500"
    assert_includes result, "Provider: perplexity"
    assert_includes result, "Perplexity answer"
    refute_includes result, "pplx-secret"
  end

  def test_auto_mode_skips_model_backed_fallbacks_unless_allowed
    http = FakeHttpClient.new(
      ["POST_JSON", "https://mcp.exa.ai/mcp"] => fake_response(500, "nope"),
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, '<div class="result"><a class="result__a" href="https://example.com/duckduckgo">DuckDuckGo</a></div>')
    )
    research = Kward::WebSearch.new(http_client: http, searxng_instances: [], config: { "web_search" => { "perplexity_api_key" => "pplx-secret" } })

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Provider: duckduckgo"
    refute http.requests.any? { |request| request[:url] == "https://api.perplexity.ai/chat/completions" }
  end

  def test_perplexity_uses_smaller_completion_budget
    perplexity_body = JSON.dump(
      "choices" => [{ "message" => { "content" => "Perplexity answer" } }],
      "citations" => []
    )
    http = FakeHttpClient.new(
      ["POST_JSON", "https://api.perplexity.ai/chat/completions"] => fake_response(200, perplexity_body)
    )
    research = Kward::WebSearch.new(http_client: http, config: { "web_search" => { "perplexity_api_key" => "pplx-secret" } })

    result = research.search("queries" => ["ruby"], "provider" => "perplexity")

    assert_includes result, "Perplexity answer"
    assert_equal 512, http.requests.first[:body]["max_tokens"]
  end

  def test_provider_answers_are_compacted_before_returning_to_model
    large_answer = "x" * 2_500
    body = JSON.dump(
      "answer" => large_answer,
      "citations" => [{ "title" => "Exa API", "url" => "https://example.com/api", "text" => "y" * 500 }]
    )
    http = FakeHttpClient.new(
      ["POST_JSON", "https://api.exa.ai/answer"] => fake_response(200, body)
    )
    research = Kward::WebSearch.new(http_client: http, config: { "web_search" => { "exa_api_key" => "exa-secret" } })

    result = research.search("queries" => ["ruby"], "provider" => "exa")

    assert_includes result, "... truncated to 2000 characters"
    assert_includes result, "... truncated to 300 characters"
  end

end
