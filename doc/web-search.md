# Web search

Web search lets the agent search and fetch live web resources. Use it when you need current facts, official docs, release notes, bug reports, pricing pages, recent announcements, or specific pages discovered during research.

Example prompts:

```text
Research the current Rails release notes and summarize migration risks.
Find the official OpenRouter docs for model configuration.
Check whether this dependency has a recent security advisory.
```

The `web_search`, `fetch_content`, and `fetch_raw` tools are advertised by default so the agent can use current sources when needed. In `auto` mode the `web_search` provider fallback order is:

1. Exa API when `EXA_API_KEY` is configured, otherwise keyless Exa MCP (`https://mcp.exa.ai/mcp`)
2. Perplexity API when configured and `allow_model_providers` is true
3. Gemini API with Google Search grounding when configured and `allow_model_providers` is true
4. DuckDuckGo HTML search, then bundled public SearXNG instances

Queries and fetched URLs are sent over the network to the selected provider or host. API keys are never bundled with Kward; configure your own keys only if you want higher limits or alternate providers. Set `web_search.enabled` to `false` to hide all web tools. Direct `provider: perplexity` or `provider: gemini` requests still use those providers when keys are configured.

## Tools

### `web_search`

Use `web_search` to discover candidate sources. It returns bounded search results with titles, URLs, snippets, and provider notes.

Supported arguments:

- `queries`: one to four search strings
- `max_results`: results per query, default 5, capped at 20
- `provider`: optional `auto`, `exa`, `perplexity`, `gemini`, or `duckduckgo`
- `recency_filter`: optional `day`, `week`, `month`, or `year`
- `domain_filter`: optional list of included domains, or excluded domains prefixed with `-`

### `fetch_content`

Use `fetch_content` after search when the agent needs to verify or quote a specific page. It follows bounded redirects, extracts readable text from HTML, strips common navigation/script noise, and limits returned content.

Supported arguments:

- `url`: HTTP or HTTPS URL to fetch
- `max_bytes`: optional maximum returned content bytes, default 16384, capped at 131072
- `extract`: optional `auto`, `text`, or `markdown`, default `auto`

### `fetch_raw`

Use `fetch_raw` for machine-readable resources where extraction would be harmful, such as JSON APIs, YAML files, OpenAPI specs, XML/RSS, or plain text source files.

Supported arguments:

- `url`: HTTP or HTTPS URL to fetch
- `max_bytes`: optional maximum returned content bytes, default 16384, capped at 131072
- `accept`: optional HTTP `Accept` header
