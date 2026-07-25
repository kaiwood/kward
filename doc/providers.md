# Model providers

Kward can keep credentials for several model providers and switch between them without changing your conversation. Use this guide to compare authentication options, see where each provider's model list comes from, and find the names used in configuration.

For login steps and credential storage, see [Authentication](authentication.md). For every config key and environment override, see [Configuration](configuration.md#Provider_and_model_settings).

## Quick start

Inside interactive Kward:

```text
/login
/model
```

`/login` connects a provider. `/model` chooses the active provider and model. The model picker can refresh the available models, accept a manual model ID, show models normally hidden by compatibility filters, or switch providers.

For example, direct OpenAI API access and ChatGPT/Codex OAuth can coexist:

1. Run `kward login` for ChatGPT/Codex.
2. Open `/login`, choose **API key**, then **OpenAI**.
3. Open `/model` and choose either **Codex** or **OpenAI**.

## Provider overview

Kward normally uses the same provider name for authentication and configuration. Direct OpenAI is the exception: authentication and private API-key storage use `openai`, while config uses `openai_api` so it cannot be confused with Codex. RPC clients also use the authentication ID.

| Provider shown in Kward | Catalog/auth ID | `provider` value | Authentication | Model source | Request API |
| --- | --- | --- | --- | --- | --- |
| Codex | — | `codex` | ChatGPT OAuth or `OPENAI_ACCESS_TOKEN` | Curated choices | ChatGPT Codex Responses, streaming |
| OpenAI | `openai` | `openai_api` | API key | Live cache with curated/manual fallback | OpenAI Responses, streaming |
| Anthropic | `anthropic` | `anthropic` | API key or Claude subscription OAuth | Curated/manual choices | Anthropic Messages, streaming |
| Azure OpenAI | `azure_openai` | `azure_openai` | API key plus Azure setup | Configured deployment | Deployment-specific Chat Completions, streaming |
| Google Gemini | `gemini` | `gemini` | API key | Live cache with curated/manual fallback | Native Gemini, streaming |
| Cerebras | `cerebras` | `cerebras` | API key | Live cache or manual ID | OpenAI-compatible Chat Completions |
| DeepSeek | `deepseek` | `deepseek` | API key | Live cache with curated/manual fallback | OpenAI-compatible Chat Completions |
| Fireworks AI | `fireworks` | `fireworks` | API key | Live cache or manual ID | OpenAI-compatible Chat Completions |
| Groq | `groq` | `groq` | API key | Live cache or manual ID | OpenAI-compatible Chat Completions |
| Mistral | `mistral` | `mistral` | API key | Live cache with curated/manual fallback | OpenAI-compatible Chat Completions |
| NVIDIA NIM | `nvidia` | `nvidia` | API key | Live cache or manual ID | OpenAI-compatible Chat Completions |
| OpenRouter | `openrouter` | `openrouter` | API key | Account-specific cache or manual ID | OpenAI-compatible Chat Completions |
| Together AI | `together` | `together` | API key | Live cache or manual ID | OpenAI-compatible Chat Completions |
| xAI | `xai` | `xai` | API key | Live cache with curated/manual fallback | OpenAI-compatible Chat Completions |
| GitHub Copilot | `copilot` | `copilot` | GitHub OAuth or `COPILOT_GITHUB_TOKEN` | Live choices with curated fallback | Copilot Responses or Chat Completions, streaming |
| Local | — | `local` | Usually none; optional local bearer key | Local server `/models` endpoint or manual ID | OpenAI-compatible Chat Completions, streaming |

“OpenAI-compatible” means Kward sends the provider's documented Chat Completions shape. It does not imply that every provider supports every OpenAI feature. Model availability, tools, images, reasoning, context limits, and billing remain provider- and model-specific.

## IDs, model keys, and environment variables

| Provider | Model config key | Model environment variable | Credential environment variable |
| --- | --- | --- | --- |
| Codex | `openai_model` | `OPENAI_MODEL` | `OPENAI_ACCESS_TOKEN` |
| OpenAI | `openai_api_model` | `OPENAI_API_MODEL` | `OPENAI_API_KEY` |
| Anthropic | `anthropic_model` | `ANTHROPIC_MODEL` | `ANTHROPIC_API_KEY` for direct API access |
| Azure OpenAI | `azure_openai_model` | `AZURE_OPENAI_MODEL` | `AZURE_OPENAI_API_KEY` |
| Google Gemini | `gemini_model` | `GEMINI_MODEL` | `GEMINI_API_KEY` |
| Cerebras | `cerebras_model` | `CEREBRAS_MODEL` | `CEREBRAS_API_KEY` |
| DeepSeek | `deepseek_model` | `DEEPSEEK_MODEL` | `DEEPSEEK_API_KEY` |
| Fireworks AI | `fireworks_model` | `FIREWORKS_MODEL` | `FIREWORKS_API_KEY` |
| Groq | `groq_model` | `GROQ_MODEL` | `GROQ_API_KEY` |
| Mistral | `mistral_model` | `MISTRAL_MODEL` | `MISTRAL_API_KEY` |
| NVIDIA NIM | `nvidia_model` | `NVIDIA_MODEL` | `NVIDIA_API_KEY` or `NGC_API_KEY` |
| OpenRouter | `openrouter_model` | `OPENROUTER_MODEL` | `OPENROUTER_API_KEY` |
| Together AI | `together_model` | `TOGETHER_MODEL` | `TOGETHER_API_KEY` |
| xAI | `xai_model` | `XAI_MODEL` | `XAI_API_KEY` |
| GitHub Copilot | `copilot_model` | `COPILOT_MODEL` | `COPILOT_GITHUB_TOKEN` |
| Local | `local_model` | `KWARD_LOCAL_MODEL` | `KWARD_LOCAL_API_KEY` when needed |

Saved API keys live in private `<config-dir>/api_keys.json`; they do not belong in the model configuration. Environment credentials take precedence over saved API keys. OAuth files and their location overrides are documented in [Authentication](authentication.md#Custom_locations).

## Choosing between similar providers

### Codex or direct OpenAI

Choose **Codex** when you want ChatGPT subscription authentication and the ChatGPT Codex backend. Choose **OpenAI** when you want an OpenAI Platform API key, public `api.openai.com` billing, and the Responses API. Their credentials and model settings are intentionally separate.

### Anthropic API or Claude subscription

Both appear as **Anthropic**. If an Anthropic API key is configured, Kward uses it before subscription OAuth. Remove or unset the API key when you specifically want the OAuth-backed subscription path.

### OpenRouter or a direct provider

OpenRouter is useful when you want one key and its cross-provider model catalog. A direct provider is useful when you want that provider's own billing, endpoint, or native runtime. Refresh OpenRouter with `/model` or:

```bash
kward openrouter refresh
kward openrouter list
```

### Cloud or Local

Choose **Local** for Ollama, LM Studio, llama.cpp, or another trusted OpenAI-compatible server. You must set the real context window yourself when the server cannot report it safely. See [Local models](local-models.md).

## Azure OpenAI setup

Azure requires:

```json
{
  "provider": "azure_openai",
  "azure_openai_endpoint": "https://example.openai.azure.com",
  "azure_openai_model": "production-gpt",
  "azure_openai_api_version": "2025-04-01-preview"
}
```

The endpoint must use HTTPS and cannot contain URL credentials, a query, or a fragment. The model value is the Azure deployment name. Kward does not attempt deployment discovery using an inference key.

## Model discovery and filtering

Kward combines several sources so a temporary catalog failure does not lock you out:

1. refreshed live metadata, when the provider exposes model discovery;
2. the last private local cache;
3. conservative curated choices, where Kward has them;
4. the currently configured model;
5. a manual ID entered in `/model`.

When capability metadata is present, the default picker prioritizes entries that advertise generation or tool/function support and hides the others. Empty or incomplete metadata stays visible. Use **Show all models** for embedding, preview, private, or unusually described models.

Model discovery proves that an ID exists; it does not guarantee account access, tool support, image support, context size, pricing, or regional availability. Provider errors remain authoritative.

## OAuth availability

Kward supports browser OAuth for ChatGPT/Codex and Anthropic, plus interactive GitHub login for Copilot. RPC can initiate OpenAI and Anthropic OAuth; Copilot OAuth remains CLI-only.

OpenRouter documents an official [OAuth PKCE flow](https://openrouter.ai/docs/guides/overview/auth/oauth), but Kward has not implemented it. xAI's public [API quickstart](https://docs.x.ai/developers/quickstart) documents API keys rather than a stable third-party subscription OAuth flow. Kward reports both limitations explicitly instead of presenting a login that cannot be completed safely.

## RPC clients

RPC clients should discover providers rather than hard-code this table:

- `auth/providers` returns catalog providers and supported authentication methods;
- `auth/status` returns sanitized configured/source state;
- `models/list` returns known model entries;
- `models/refresh` refreshes a provider when supported;
- `models/set` selects the provider and model.

See the [RPC protocol](rpc.md#Config_and_auth_methods) for request shapes and unsupported OAuth capability reporting.
