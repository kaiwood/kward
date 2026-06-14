# Authentication

Kward needs credentials for a model provider before it can answer prompts. The easiest path is to start Kward and run `/login`.

Kward supports:

- OpenAI/ChatGPT OAuth for the Codex backend.
- Anthropic OAuth for Claude Pro/Max subscription support.
- OpenRouter API keys.
- GitHub OAuth or `COPILOT_GITHUB_TOKEN` for experimental Copilot provider support.

If you installed the gem, use `kward` in the examples below. When running from source, use `ruby lib/main.rb` instead.

## Quick login

Inside an interactive session:

```text
/login
```

Kward opens a provider picker and saves the selected credentials.

From your shell, you can also run:

```bash
kward login              # OpenAI/ChatGPT OAuth
kward login anthropic    # Anthropic Claude Pro/Max OAuth
kward login openrouter   # save an OpenRouter API key
kward login github       # GitHub OAuth for experimental Copilot support
```

## OpenAI OAuth

OpenAI OAuth is the default provider path when credentials are available. It uses your ChatGPT account and sends requests to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the OpenAI Platform API.

To start the browser login from your shell:

```bash
kward login
```

In an interactive session, run `/login` and choose OpenAI.

Complete the browser redirect flow. Tokens are saved to:

```text
~/.kward/auth.json
```

The auth file is written with file mode `0600`.

OpenAI OAuth requires an OAuth client ID in `~/.kward/config.json`:

```json
{
  "openai_oauth_client_id": "your-client-id"
}
```

If it is missing, Kward tells you which config file to update.

## Anthropic OAuth

Anthropic OAuth uses your Claude Pro/Max subscription and sends requests to the Anthropic Messages API with Claude Code-compatible subscription headers. To start the browser login from your shell:

```bash
kward login anthropic
```

In an interactive session, run `/login` and choose Anthropic.

Tokens are saved to:

```text
~/.kward/anthropic_auth.json
```

The auth file is written with file mode `0600`. Kward refreshes the access token when the saved refresh token is available.

Important: Anthropic subscription access follows the same direct OAuth approach Pi uses for Claude Pro/Max. Subscription provider behavior may change upstream.

## OpenRouter API key

OpenRouter uses an API key rather than OAuth. To save it from your shell:

```bash
kward login openrouter
```

In an interactive session, run `/login` and choose OpenRouter.

Kward saves the key as `openrouter_api_key` in `~/.kward/config.json`. You can also set `OPENROUTER_API_KEY` for a single run without saving it.

## GitHub OAuth for Copilot provider support

Kward can use a GitHub token for experimental Copilot provider support.

The GitHub device flow uses a built-in default client ID unless you set `GITHUB_OAUTH_CLIENT_ID` or add `github_oauth_client_id` to `~/.kward/config.json`. To log in:

```bash
kward login github
```

Tokens are saved to:

```text
~/.kward/github_auth.json
```

The auth file is written with file mode `0600`.

You can also run `/login` in an interactive session and choose GitHub, or provide `COPILOT_GITHUB_TOKEN` for a single run.

Important: Kward's Copilot provider follows Pi Agent's direct HTTPS approach. It exchanges the GitHub OAuth token for a Copilot internal token and sends chat requests to the Copilot proxy API. It does not use the official Copilot CLI or SDK runtime.

## Fallback and provider selection

Credential priority is provider-aware:

- OpenAI OAuth is used by default after login, even when `OPENROUTER_API_KEY` or `openrouter_api_key` is also present.
- Anthropic OAuth is used when `provider` or `KWARD_PROVIDER` selects `anthropic` or `claude`.
- `OPENAI_ACCESS_TOKEN` can be used as an OpenAI environment fallback.
- `OPENROUTER_API_KEY` is a fallback only when no OpenAI OAuth/access token exists.
- `COPILOT_GITHUB_TOKEN` can be used as a Copilot environment fallback.
- If `provider` in config or `KWARD_PROVIDER` in the environment is set to `codex`, `anthropic`, `openrouter`, or `copilot`, Kward uses that provider and does not fall through to another provider.

See [Configuration](configuration.md) for model and provider settings.
