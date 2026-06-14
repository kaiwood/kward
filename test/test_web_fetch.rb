require_relative "test_helper"

class TestWebFetch < KwardTestCase
  def test_fetch_content_extracts_readable_html
    html = <<~HTML
      <html>
        <head><title>Example Article</title><script>ignore()</script></head>
        <body>
          <nav>Navigation</nav>
          <article>
            <h1>Main heading</h1>
            <p>First paragraph.</p>
            <ul><li>Useful item</li></ul>
          </article>
        </body>
      </html>
    HTML
    http = FakeHttpClient.new(
      "GET" => nil,
      ["GET", "https://example.com/article"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/article")

    assert_includes result, "# Fetched content"
    assert_includes result, "- URL: https://example.com/article"
    assert_includes result, "# Example Article"
    assert_includes result, "# Main heading"
    assert_includes result, "First paragraph."
    assert_includes result, "- Useful item"
    refute_includes result, "Navigation"
    refute_includes result, "ignore()"
  end

  def test_fetch_content_follows_redirects
    http = FakeHttpClient.new(
      ["GET", "https://example.com/start"] => fake_response(302, "", headers: { "location" => "/final" }),
      ["GET", "https://example.com/final"] => fake_response(200, "<html><body><main><p>Arrived.</p></main></body></html>", headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/start")

    assert_includes result, "- URL: https://example.com/final"
    assert_includes result, "Arrived."
  end

  def test_fetch_content_rejects_non_http_urls
    fetch = Kward::WebFetch.new(http_client: FakeHttpClient.new({}))

    result = fetch.fetch_content("url" => "file:///etc/passwd")

    assert_equal "Error: fetch_content failed: url must use http or https", result
  end

  def test_fetch_raw_returns_bounded_raw_content_with_accept_header
    http = FakeHttpClient.new(
      ["GET", "https://example.com/openapi.json"] => fake_response(200, "{\"openapi\":\"3.1.0\"}", headers: { "content-type" => "application/json" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_raw("url" => "https://example.com/openapi.json", "accept" => "application/json")

    assert_includes result, "# Fetched raw content"
    assert_includes result, "application/json"
    assert_includes result, "{\"openapi\":\"3.1.0\"}"
    assert_equal "application/json", http.requests.first[:headers]["Accept"]
  end

  def test_fetch_raw_truncates_large_content
    http = FakeHttpClient.new(
      ["GET", "https://example.com/large.txt"] => fake_response(200, "x" * 20, headers: { "content-type" => "text/plain" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_raw("url" => "https://example.com/large.txt", "max_bytes" => 8)

    assert_includes result, "xxxxxxxx"
    assert_includes result, "... truncated to 8 bytes"
  end
end
