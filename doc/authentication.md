# Authentication

## OpenAI OAuth

Put `openai_oauth_client_id` in `~/.kward/config.json`, then run:

```bash
ruby lib/main.rb login
```

Complete the browser redirect flow. OAuth tokens are saved to `~/.kward/auth.json` with file mode `0600`.

OpenAI OAuth is used by default after login, even if `OPENROUTER_API_KEY` is set. OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the Platform API, so they use your ChatGPT account.

## Fallback authentication

`OPENROUTER_API_KEY` is only a fallback when no OpenAI OAuth/access token exists. `OPENAI_ACCESS_TOKEN` can also be used as an environment fallback.
