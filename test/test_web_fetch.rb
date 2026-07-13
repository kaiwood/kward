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

  def test_fetch_content_prefers_main_over_nested_article_cards
    html = <<~HTML
      <html><head><title>Home</title></head><body>
        <nav><a href="/guide">Guide</a></nav>
        <main>
          <h1>Welcome</h1>
          <p><a href="/start">Get started</a> with the project.</p>
          <section>
            <article><h2>First card</h2><p>One.</p></article>
            <article><h2>Second card</h2><p>Two.</p></article>
          </section>
          <a href="/install">Installation docs</a>
        </main>
      </body></html>
    HTML
    http = FakeHttpClient.new(
      ["GET", "https://example.com/"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/")

    assert_includes result, "# Welcome"
    assert_includes result, "## First card"
    assert_includes result, "## Second card"
    assert_includes result, "[Get started](https://example.com/start) with the project."
    assert_includes result, "[Installation docs](https://example.com/install)"
    assert_includes result, "### Primary navigation"
    assert_includes result, "[Guide](https://example.com/guide)"
    refute_includes result, "\n\nNavigation\n\n"
  end

  def test_fetch_content_preserves_tables_and_nested_lists
    html = <<~HTML
      <html><body><main>
        <ol><li>First<ul><li>Nested</li></ul></li><li>Second</li></ol>
        <table><thead><tr><th>Command</th><th>Action</th></tr></thead>
          <tbody><tr><td><code>/tab new</code></td><td><a href="/tabs">Open a tab</a></td></tr></tbody>
        </table>
      </main></body></html>
    HTML
    http = FakeHttpClient.new(
      ["GET", "https://example.com/reference"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/reference")

    assert_includes result, "1. First\n  - Nested\n2. Second"
    assert_includes result, "| Command | Action |"
    assert_includes result, "| `/tab new` | [Open a tab](https://example.com/tabs) |"
  end

  def test_fetch_content_text_mode_keeps_link_destinations
    html = '<html><body><main><p>Read <a href="/guide">the guide</a>.</p></main></body></html>'
    http = FakeHttpClient.new(
      ["GET", "https://example.com/start"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/start", "extract" => "text")

    assert_includes result, "Read the guide (https://example.com/guide)."
  end

  def test_fetch_content_parses_html_beyond_output_limit
    html = "<html><head><title>Large page</title><script>#{"x" * 20_000}</script></head><body><main><h1>Tabs</h1><p>Readable guide body.</p></main></body></html>"
    http = FakeHttpClient.new(
      ["GET", "https://example.com/tabs"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/tabs")

    assert_includes result, "# Tabs"
    assert_includes result, "Readable guide body."
    refute_includes result, "x" * 100
  end

  def test_fetch_content_text_mode_extracts_plain_text_from_html
    html = "<html><head><title>Guide</title></head><body><main><h1>Start</h1><p>Read me.</p></main></body></html>"
    http = FakeHttpClient.new(
      ["GET", "https://example.com/guide"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/guide", "extract" => "text")

    assert_includes result, "Guide\n\nStart\n\nRead me."
    refute_includes result, "<html>"
    refute_includes result, "# Start"
  end

  def test_fetch_content_does_not_duplicate_nested_code
    html = "<html><body><main><pre><code>puts :ok</code></pre></main></body></html>"
    http = FakeHttpClient.new(
      ["GET", "https://example.com/code"] => fake_response(200, html, headers: { "content-type" => "text/html" })
    )
    fetch = Kward::WebFetch.new(http_client: http)

    result = fetch.fetch_content("url" => "https://example.com/code")

    assert_equal 1, result.scan("puts :ok").length
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
