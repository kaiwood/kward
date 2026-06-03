require_relative "test_helper"

class TestWebResearch < KwardTestCase
  def test_web_research_uses_duckduckgo_results
    html = '<div class="result"><a class="result__a" href="https://example.com/ruby">Ruby News</a><a class="result__snippet">Ruby release notes</a></div>'
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, html)
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: [])

    result = research.search("queries" => ["ruby news"])

    assert_includes result, "# Web research"
    assert_includes result, "Provider: duckduckgo"
    assert_includes result, "Ruby News"
    assert_includes result, "https://example.com/ruby"
  end

  def test_web_research_falls_back_to_searxng_json
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(429, "rate limited"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(200, JSON.dump(
        "results" => [{ "title" => "Fallback Result", "url" => "https://example.com/fallback", "content" => "search snippet" }]
      ))
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Provider fallback note: DuckDuckGo search failed with HTTP 429"
    assert_includes result, "Provider: searxng"
    assert_includes result, "search snippet"
  end

  def test_web_research_uses_searxng_html_when_json_is_disabled
    html = '<article class="result"><h3><a href="https://example.com/html-page">HTML Result</a></h3><p class="content">HTML snippet</p></article>'
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(500, "nope"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(403, "json disabled"),
      ["GET", "https://searx.test/search?q=ruby"] => fake_response(200, html)
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"])

    assert_includes result, "HTML Result"
    assert_includes result, "HTML snippet"
  end

  def test_web_research_returns_clear_error_when_all_providers_fail
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(500, "nope"),
      ["GET", "https://searx.test/search?q=ruby&format=json"] => fake_response(403, "json disabled")
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: ["https://searx.test"])

    result = research.search("queries" => ["ruby"])

    assert_includes result, "Error: web_research found no results"
    assert_includes result, "DuckDuckGo search failed with HTTP 500"
    assert_includes result, "SearXNG search failed with HTTP 403"
  end

  def test_web_research_truncates_large_output
    html = "<div class=\"result\"><a class=\"result__a\" href=\"https://example.com/large\">Large</a><a class=\"result__snippet\">#{"x" * 500}</a></div>"
    http = FakeHttpClient.new(
      ["POST", "https://html.duckduckgo.com/html/"] => fake_response(200, html)
    )
    research = Kward::WebResearch.new(http_client: http, searxng_instances: [], max_output_bytes: 120)

    result = research.search("queries" => ["ruby"])

    assert_includes result, "... truncated to 120 bytes"
  end

end
