# Authentication

## OpenAI OAuth

Put `openai_oauth_client_id` in `~/.kward/config.json`, then run:

```bash
ruby lib/main.rb login
```

Complete the browser redirect flow. OAuth tokens are saved to `~/.kward/auth.json` with file mode `0600`.

In an interactive session, run `/login` and choose OpenAI from the provider picker to start the same OAuth flow.

OpenAI OAuth is used by default after login, even if `OPENROUTER_API_KEY` is set. OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the Platform API, so they use your ChatGPT account.

## GitHub OAuth for Copilot scaffolding

Kward can store a GitHub OAuth token for future GitHub Copilot subscription support. Add `github_oauth_client_id` to `~/.kward/config.json`, then run:

```bash
ruby lib/main.rb login github
```

The GitHub device flow saves tokens to `~/.kward/github_auth.json` with file mode `0600`. You can also run `/login` in an interactive session and choose GitHub from the provider picker. You can also provide `COPILOT_GITHUB_TOKEN` for a single run.

Important: Kward's Copilot provider follows Pi Agent's direct HTTPS approach: it exchanges the GitHub OAuth token for a Copilot internal token and sends chat requests to the Copilot proxy API. This does not use the official Copilot CLI/SDK runtime.

## Fallback authentication

`OPENROUTER_API_KEY` is only a fallback when no OpenAI OAuth/access token exists. `OPENAI_ACCESS_TOKEN` can also be used as an environment fallback. If `provider` or `KWARD_PROVIDER` is set to `openrouter` or `copilot`, Kward uses that provider and does not fall back to OpenAI/OpenRouter.
