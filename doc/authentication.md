# Authentication

Kward needs credentials for a model provider before it can answer prompts. It supports:

- OpenAI/ChatGPT OAuth for the Codex backend.
- OpenRouter API keys.
- GitHub OAuth or `COPILOT_GITHUB_TOKEN` for experimental Copilot provider support.

If you installed the gem, use `kward` in the examples below. When running from source, use `ruby lib/main.rb` instead.

## OpenAI OAuth

OpenAI OAuth is the default provider path when credentials are available. First add an OAuth client ID to `~/.kward/config.json`:

```json
{
  "openai_oauth_client_id": "your-client-id"
}
```

Then run:

```bash
kward login
```

Complete the browser redirect flow. Tokens are saved to:

```text
~/.kward/auth.json
```

The auth file is written with file mode `0600`.

In an interactive session, run `/login` and choose OpenAI from the provider picker to start the same flow.

OpenAI OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the OpenAI Platform API, so they use your ChatGPT account.

## OpenRouter API key

OpenRouter uses an API key rather than OAuth. To save it in `~/.kward/config.json`, run:

```bash
kward login openrouter
```

In an interactive session, run `/login` and choose OpenRouter. You can also set `OPENROUTER_API_KEY` for a single run.

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
- `OPENAI_ACCESS_TOKEN` can be used as an OpenAI environment fallback.
- `OPENROUTER_API_KEY` is a fallback only when no OpenAI OAuth/access token exists.
- `COPILOT_GITHUB_TOKEN` can be used as a Copilot environment fallback.
- If `provider` in config or `KWARD_PROVIDER` in the environment is set to `codex`, `openrouter`, or `copilot`, Kward uses that provider and does not fall through to another provider.

See [Configuration](configuration.md) for model and provider settings.
