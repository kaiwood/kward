# Web search

Use web search when the answer depends on current or external information:

- current framework or dependency docs,
- release notes and migration guides,
- security advisories,
- pricing or provider pages,
- bug reports and issue discussions,
- a specific URL you want Kward to inspect.

Example prompts:

```text
Check the current Rails release notes and summarize migration risks for this project.
Find the official OpenRouter docs for model configuration.
Check whether this dependency has a recent security advisory.
Read this URL and explain the setup steps: https://example.com/docs
```

## How Kward researches

Kward has three web tools:

1. `web_search` finds candidate sources.
2. `fetch_content` reads human-readable pages.
3. `fetch_raw` reads machine-readable files such as JSON, YAML, XML, RSS, OpenAPI specs, or plain text.

A good research flow is:

```text
Search for the official docs, fetch the relevant page, then answer with the source URL.
```

Kward should search first, then fetch important pages before relying on them.

## Network behavior

Web tools are advertised to the model by default. Queries and fetched URLs are sent over the network to the selected provider or target host. See [Configuration](configuration.md) for the full `web_search` config reference including API key storage and the `provider` config setting.

In automatic mode, provider fallback is:

1. Exa API when `EXA_API_KEY` is configured, otherwise keyless Exa MCP.
2. Perplexity API when `PERPLEXITY_API_KEY` is configured and model-provider fallback is allowed.
3. Gemini API with Google Search grounding when `GEMINI_API_KEY` is configured and model-provider fallback is allowed.
4. DuckDuckGo HTML search, then bundled public SearXNG instances.

You do not need an API key for basic web search, but keys can improve limits or provider choice. The default provider can also be set in config as `web_search.provider`; the tool argument overrides it for a single call.

Search output is capped at 8 KB total, with excerpts up to 300 characters and answer text up to 2,000 characters. HTTP requests use a 10-second timeout.

## Disable web tools

Hide all web tools:

```json
{
  "web_search": {
    "enabled": false
  }
}
```

Use this when working on private projects where no prompt should trigger external lookup.

## Tool details

### `web_search`

Finds candidate sources. Arguments:

- `queries`: one to four search strings.
- `max_results`: results per query, default 5, capped at 20.
- `provider`: optional `auto`, `exa`, `perplexity`, `gemini`, or `duckduckgo`.
- `recency_filter`: optional `day`, `week`, `month`, or `year`.
- `domain_filter`: optional domains to include, or domains prefixed with `-` to exclude.

### `fetch_content`

Reads a specific HTTP or HTTPS page and extracts readable text. Use it for docs pages, articles, issues, and release notes.

Arguments:

- `url`
- `max_bytes`: default 16384, capped at 131072.
- `extract`: optional `auto`, `text`, or `markdown`.

In `auto` mode (default), Kward detects HTML content and extracts readable text by stripping scripts, styles, navigation, and forms, preserving headings, paragraphs, lists, code blocks, and blockquotes. Non-HTML content is returned as cleaned text. Use `markdown` to format extracted headings and code blocks as Markdown, or `text` for plain text without formatting.

Fetches follow up to 5 redirects and use a 10-second HTTP timeout.

### `fetch_raw`

Reads a specific HTTP or HTTPS resource without readability extraction. Use it for JSON, YAML, XML, RSS, OpenAPI specs, and plain text.

Arguments:

- `url`
- `max_bytes`: default 16384, capped at 131072.
- `accept`: optional HTTP `Accept` header.

Fetches follow up to 5 redirects and use a 10-second HTTP timeout.
