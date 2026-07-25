# Authentication

Kward can keep credentials for several model providers at once. Authentication and model selection are separate: connect an account or API key first, then use `/model` to choose what runs. See [Model providers](providers.md) for the canonical provider, runtime, model-key, and environment-variable reference.

The easiest setup is inside interactive Kward:

```text
/login
```

Choose **API key** or **Subscription / OAuth**, then choose a provider. After login, open:

```text
/model
```

## Supported authentication

| Provider | API key | Subscription / OAuth |
| --- | --- | --- |
| OpenAI | Yes, direct OpenAI API | Yes, ChatGPT/Codex |
| Anthropic | Yes, direct Anthropic API | Yes, Claude Pro/Max |
| Azure OpenAI | Yes; endpoint, deployment, and API version are also required | No |
| Google Gemini | Yes | No |
| Cerebras, DeepSeek, Fireworks AI, Groq, Mistral, NVIDIA NIM, Together AI | Yes | No |
| OpenRouter | Yes | Not yet in Kward |
| xAI | Yes | No supported third-party flow |
| GitHub Copilot | No API-key mode | Yes |

Direct OpenAI API credentials and ChatGPT/Codex OAuth are independent. You can keep both and switch between **OpenAI** and **Codex** in `/model`.

## API-key workflow

From `/login`, choose **API key** and the provider. Kward validates providers with live model discovery before saving the key, then stores it in:

```text
~/.kward/api_keys.json
```

The file is private (`0600` when supported). It is separate from `config.json`, so normal config reads and RPC responses do not return keys.

For providers that do not also offer subscription login, the shell command is convenient:

```bash
kward login groq
kward login gemini
kward login openrouter
kward login azure_openai
```

Use the interactive `/login` method picker for direct OpenAI or Anthropic API keys because `kward login openai` and `kward login anthropic` retain their subscription-login behavior.

Environment variables override a stored key for that provider:

```bash
OPENAI_API_KEY=... kward
GEMINI_API_KEY=... kward
GROQ_API_KEY=... kward
```

Other supported variables are listed in [Configuration](configuration.md#Environment_overrides).

### Azure OpenAI

Azure setup asks for three non-secret values after the key:

- an HTTPS endpoint, such as `https://example.openai.azure.com`;
- a deployment name;
- an API version, such as `2025-04-01-preview`.

Kward rejects endpoint credentials, query strings, fragments, and unsafe deployment/version characters. The deployment is the model shown in `/model`; Kward does not claim to discover Azure deployments from an inference key.

## ChatGPT / Codex OAuth

```bash
kward login
```

Credentials are saved to `~/.kward/auth.json`. This uses the ChatGPT/Codex backend, not `OPENAI_API_KEY` or the public OpenAI API endpoint.

For one shell session, you can provide the Codex access token directly:

```bash
OPENAI_ACCESS_TOKEN=... kward
```

`OPENAI_ACCESS_TOKEN` continues to mean Codex OAuth. `OPENAI_API_KEY` means direct OpenAI API access; neither replaces the other.

## Anthropic Claude Pro/Max

```bash
kward login anthropic
```

OAuth credentials are saved to `~/.kward/anthropic_auth.json`. Kward refreshes the access token when a refresh token is available. Choose **API key** in `/login` instead when you want direct Anthropic API billing.

## GitHub Copilot

```bash
kward login github
```

Credentials are saved to `~/.kward/github_auth.json`. For one run, use `COPILOT_GITHUB_TOKEN`. General `GH_TOKEN` and `GITHUB_TOKEN` values are not treated as Copilot credentials.

## OpenRouter

API-key login is supported, including model refresh:

```bash
kward login openrouter
kward openrouter refresh
kward openrouter list
```

The cache lives at `<config-dir>/cache/openrouter_models.json`. `/model` can also refresh the active provider directly.

OpenRouter documents an official [OAuth PKCE flow](https://openrouter.ai/docs/guides/overview/auth/oauth), but Kward does not implement that flow yet. It remains unavailable in CLI and RPC capabilities rather than exposing an unverified partial login.

xAI's public inference documentation currently directs clients to API keys (see the [xAI quickstart](https://docs.x.ai/developers/quickstart)); Kward does not expose an xAI subscription OAuth flow.

## Model selection

The provider-aware `/model` picker offers:

- **Refresh model list**;
- **Enter model ID manually**;
- **Show all models**;
- **Change provider**.

By default, Kward hides entries when provider metadata proves they are not generation/tool models. It keeps entries whose metadata is incomplete. **Show all models** and manual IDs remain available for previews, private deployments, and incomplete catalogs.

## Status and logout

```bash
kward auth status
kward auth logout
```

Status reports only whether credentials exist and where they came from; it never prints credential values. CLI logout removes all saved OAuth and API-key credentials. Environment variables remain active until you unset them.

RPC clients can list catalog providers, inspect sanitized method availability, save/remove individual API keys, and remove a specific provider/auth method. See [RPC](rpc.md#Config_and_auth_methods).

## Custom locations

- `KWARD_CONFIG_PATH` moves `config.json`, `api_keys.json`, caches, and most other Kward state to that file's directory.
- `KWARD_AUTH_PATH` overrides ChatGPT/Codex OAuth storage.
- `KWARD_ANTHROPIC_AUTH_PATH` overrides Anthropic OAuth storage.
- `KWARD_GITHUB_AUTH_PATH` overrides GitHub Copilot OAuth storage.

Never commit credential files. For temporary credentials, prefer environment variables and unset them when finished.
