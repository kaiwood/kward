# Authentication

Kward needs access to a model provider before it can answer prompts. The fastest path is:

```bash
kward login
```

Or inside interactive Kward:

```text
/login
```

`/login` opens a provider picker; `kward login` accepts the provider as an argument.

Use the provider you already have access to. You can change the active model later with `/model`.

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

Kward ships with a built-in client ID, so this is only needed if login fails or you want to use your own.

For a single shell session without OAuth, you can set an access token directly:

```bash
OPENAI_ACCESS_TOKEN=... kward
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

### Refresh the OpenRouter model cache

Kward's `/model` picker can show OpenRouter models that are available to your API key. Refresh the local cache after logging in:

```bash
kward openrouter refresh
```

This fetches text-capable OpenRouter models for the configured key and writes them to:

```text
~/.kward/cache/openrouter_models.json
```

If `KWARD_CONFIG_PATH` points at a custom config file, the cache is written beside that config file under `cache/openrouter_models.json`.

Inspect the cached model ids with:

```bash
kward openrouter list
```

Use this when:

- you added or changed your OpenRouter API key,
- OpenRouter added new models,
- your model picker does not show the model you expect,
- you want Kward to use current context-window metadata from OpenRouter.

After refreshing, start Kward and choose the model with `/model`.

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

## Choose the active model

Authentication makes providers available. The active model is selected separately.

Inside Kward, use:

```text
/model
```

The model picker is the normal way to switch between configured providers and models. You can keep credentials for multiple providers and choose the model you want for the current work.

For one-off shell runs, `KWARD_PROVIDER` and provider-specific model environment variables remain available. See [Configuration](configuration.md) for the full list.

## Custom auth file locations

Each auth file has an environment variable override, useful for isolated or multi-account setups. When unset, they default to the paths shown above under `~/.kward/`.

- `KWARD_AUTH_PATH` — OpenAI OAuth credentials (`auth.json`)
- `KWARD_ANTHROPIC_AUTH_PATH` — Anthropic OAuth credentials (`anthropic_auth.json`)
- `KWARD_GITHUB_AUTH_PATH` — GitHub OAuth credentials (`github_auth.json`)

When `KWARD_CONFIG_PATH` points at a custom config file, the OpenRouter API key is stored in that file instead of `~/.kward/config.json`.

## Security notes

- Auth files are written with file mode `0600` when possible.
- Do not commit `~/.kward/config.json` or auth files.
- Prefer environment variables for temporary credentials.
- `kward auth status` shows credential status without printing secrets.
- `kward auth logout` removes **all** saved credentials at once: every OAuth file (OpenAI, Anthropic, GitHub) and the stored OpenRouter API key. There is no per-provider logout; to remove a single provider, delete its auth file by hand.
- `kward doctor` reports which credentials are currently configured alongside other local checks.
