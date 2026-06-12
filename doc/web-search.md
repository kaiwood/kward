# Web search

Web search lets the agent search the live web. Use it when you need current facts, official docs, release notes, bug reports, pricing pages, or recent announcements.

Example prompts:

```text
Research the current Rails release notes and summarize migration risks.
Find the official OpenRouter docs for model configuration.
Check whether this dependency has a recent security advisory.
```

The `web_search` tool is advertised by default so the agent can use current sources when needed. In `auto` mode the provider fallback order is:

1. Exa API when `EXA_API_KEY` is configured, otherwise keyless Exa MCP (`https://mcp.exa.ai/mcp`)
2. Perplexity API when configured and `allow_model_providers` is true
3. Gemini API with Google Search grounding when configured and `allow_model_providers` is true
4. Legacy DuckDuckGo HTML search, then bundled public SearXNG instances

Queries are sent over the network to the selected provider. API keys are never bundled with Kward; configure your own keys only if you want higher limits or alternate providers. Set `web_search.enabled` to `false` to hide the tool. Direct `provider: perplexity` or `provider: gemini` requests still use those providers when keys are configured.

Supported arguments:

- `queries`: one to four search strings
- `max_results`: results per query, default 5, capped at 20
- `provider`: optional `auto`, `exa`, `perplexity`, `gemini`, `legacy`, or `duckduckgo`
- `recency_filter`: optional `day`, `week`, `month`, or `year`
- `domain_filter`: optional list of included domains, or excluded domains prefixed with `-`
