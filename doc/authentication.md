# Authentication

Kward needs access to a model provider before it can answer prompts. The fastest path is:

```bash
kward login
```

Or inside interactive Kward:

```text
/login
```

Use the provider you already have access to. You can change providers later.

## Choose a provider

| Provider | Use it when... |
| --- | --- |
| OpenAI/ChatGPT | You want the default Codex backend with a ChatGPT account. |
| Anthropic | You have Claude Pro/Max and want to use Claude through Kward. |
| OpenRouter | You want to use an OpenRouter API key and choose from its model catalog. |
| Copilot | You want to try experimental Copilot provider support. |

If you are unsure, start with `kward login` and choose OpenAI.

## Login commands

```bash
kward login              # OpenAI/ChatGPT OAuth
kward login anthropic    # Anthropic Claude Pro/Max OAuth
kward login openrouter   # OpenRouter API key
kward login github       # GitHub OAuth for experimental Copilot support
```

From source, replace `kward` with `ruby lib/main.rb`.

## OpenAI / ChatGPT

```bash
kward login
```

This opens a browser login and saves credentials to:

```text
~/.kward/auth.json
```

Kward uses the ChatGPT/Codex backend, not the OpenAI Platform API key flow.

If Kward asks for an OAuth client ID, add it to `~/.kward/config.json`:

```json
{
  "openai_oauth_client_id": "your-client-id"
}
```

## Anthropic Claude Pro/Max

```bash
kward login anthropic
```

This saves credentials to:

```text
~/.kward/anthropic_auth.json
```

Use this when you want Kward to use your Claude Pro/Max subscription. Kward refreshes the access token when a refresh token is available.

## OpenRouter

```bash
kward login openrouter
```

This stores your API key in `~/.kward/config.json`.

For a single shell session, you can avoid saving the key:

```bash
OPENROUTER_API_KEY=sk-or-v1-... kward
```

Choose OpenRouter when you want access to its model catalog or want provider/model selection through an API key.

## Experimental Copilot support

```bash
kward login github
```

This saves GitHub OAuth credentials to:

```text
~/.kward/github_auth.json
```

You can also use a token for one run:

```bash
COPILOT_GITHUB_TOKEN=... kward
```

Copilot support is experimental and uses direct HTTPS calls to the Copilot proxy API. It does not use the official Copilot CLI or SDK runtime.

## Which credential wins?

If multiple credentials are available, Kward uses the configured provider.

Set it in `~/.kward/config.json`:

```json
{
  "provider": "anthropic"
}
```

Or for one command:

```bash
KWARD_PROVIDER=openrouter kward
```

Supported provider values:

```text
codex
anthropic
openrouter
copilot
```

Without an explicit provider, OpenAI/ChatGPT credentials are preferred when present.

## Security notes

- Auth files are written with file mode `0600` when possible.
- Do not commit `~/.kward/config.json` or auth files.
- Prefer environment variables for temporary credentials.
- `kward auth status` shows credential status without printing secrets.
- `kward auth logout` removes saved credentials.
