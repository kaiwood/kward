# Configuration

Kward reads user configuration from `~/.kward/config.json` by default. Most users do not need to edit this file by hand at first: use `/login`, `/model`, `/reasoning`, and `/settings` from inside Kward when possible.

On first start, if the file does not exist, Kward creates a starter config with the current runtime defaults and an active Kward persona so you can inspect and edit them. If `KWARD_CONFIG_PATH` is set, Kward uses that file instead and treats that file's directory as the config directory for prompts, skills, memory, logs, and caches.

Small examples:

```json
{
  "provider": "openrouter",
  "openrouter_model": "openai/gpt-5.5"
}
```

```json
{
  "memory": {
    "enabled": true
  }
}
```

## Config directory

By default, Kward stores user data under `~/.kward`:

```text
~/.kward/config.json
~/.kward/auth.json
~/.kward/github_auth.json
~/.kward/sessions/
~/.kward/memory/
~/.kward/logs/
~/.kward/cache/
```

When `KWARD_CONFIG_PATH=/path/to/config.json` is set, most config-related files live beside that file instead. User plugins are the exception: they are loaded only from `~/.kward/plugins`.

## Provider and model settings

Set `provider` to choose the active backend:

```json
{
  "provider": "codex"
}
```

Supported values are:

- `codex` for the OpenAI/ChatGPT Codex backend.
- `openrouter` for OpenRouter.
- `copilot` for experimental Copilot provider support.

Model settings:

```json
{
  "model": "gpt-5.5",
  "openai_model": "gpt-5.5",
  "openrouter_model": "openai/gpt-5.5",
  "copilot_model": "gpt-5-mini",
  "reasoning_effort": "medium",
  "openai_reasoning_effort": "medium",
  "openrouter_reasoning_effort": "medium",
  "copilot_reasoning_effort": "medium",
  "thinking_level": "medium"
}
```

`model` is a generic setting for the active provider. Provider-specific values such as `openai_model`, `openrouter_model`, and `copilot_model` take precedence for their provider. `reasoning_effort` and `thinking_level` are generic reasoning settings. `openai_reasoning_effort`, `openrouter_reasoning_effort`, and `copilot_reasoning_effort` are provider-specific forms.

Defaults:

- OpenAI/Codex: `gpt-5.5`
- OpenRouter: `openai/gpt-5.5`
- Copilot: `gpt-5-mini`
- Reasoning effort: `medium`

The interactive `/model` picker prefers OpenRouter models available to the configured API key when Kward can fetch them. `/openrouter/catalog` and RPC `openrouter/catalog` list the full OpenRouter catalog separately.

## Environment overrides

Use environment variables for one-off runs or local secrets that you do not want in config.

Provider and model:

- `KWARD_PROVIDER`
- `OPENAI_MODEL`
- `OPENAI_REASONING_EFFORT`
- `OPENROUTER_MODEL`
- `OPENROUTER_REASONING_EFFORT`
- `COPILOT_MODEL`
- `COPILOT_REASONING_EFFORT`

Credentials:

- `OPENAI_ACCESS_TOKEN`
- `OPENROUTER_API_KEY`
- `COPILOT_GITHUB_TOKEN`
- `GITHUB_TOKEN` or `GH_TOKEN` for authenticated GitHub API requests in `code_search`

Web search:

- `EXA_API_KEY`
- `PERPLEXITY_API_KEY`
- `GEMINI_API_KEY`

Color and logging environment variables are covered below.

## Authentication settings

The friendliest way to configure credentials is `/login` inside Kward, or `kward login` from your shell. See [Authentication](authentication.md) for the full provider flow.

Credential settings can also live in config:

```json
{
  "openai_oauth_client_id": "your-client-id",
  "openrouter_api_key": "sk-or-v1-..."
}
```

Use environment variables for temporary or local-only secrets when possible. If both OpenAI and OpenRouter credentials are available, OpenAI OAuth is used by default unless `provider` or `KWARD_PROVIDER` selects another backend.

## Overlay settings

Overlay settings control terminal picker/card layout:

```json
{
  "overlay": {
    "alignment": "center",
    "width": "maximum"
  }
}
```

`alignment` can be `left`, `center`, or `right`. `width` can be `maximum` to match the composer width or `capped` for a compact card.

You can change these interactively with `/settings`.

## Composer settings

The busy composer shows a short Ctrl+C cancellation hint by default. To hide it:

```json
{
  "composer": {
    "busy_help": false
  }
}
```

This only hides the hint text; Ctrl+C still stops the current running response.

## Memory

Memory is off by default. Enabling it writes:

```json
{
  "memory": {
    "enabled": true
  }
}
```

Memory auto-summary can also be enabled:

```json
{
  "memory": {
    "enabled": true,
    "auto_summary": true
  }
}
```

Memory files live under `<config-dir>/memory`, usually `~/.kward/memory`. See [Memory](memory.md).

## Compaction

Auto-compaction is enabled by default when Kward can determine the active context window. You can tune or disable it:

```json
{
  "compaction": {
    "enabled": true,
    "reserve_tokens": 16384,
    "keep_recent_tokens": 20000
  }
}
```

Manual `/compact [instructions]` works even when auto-compaction is disabled.

## Pan mode

`--pan-mode` starts a LAN-reachable web UI and requires HTTP Basic Auth. Configure credentials before starting it:

```json
{
  "pan_mode": {
    "host": "0.0.0.0",
    "port": 8765,
    "username": "kward",
    "password": "choose-a-private-password"
  }
}
```

`host` defaults to `0.0.0.0` and `port` defaults to `8765`. Kward fails to start pan mode unless `username` and `password` are configured.

These credentials are stored in plaintext config. Use a private, user-specific password and do not share the config file. Pan mode exposes the agent's file, shell, and web tools to anyone on the LAN who has the credentials, so use it only on trusted networks.

## Web search

Web search works without an API key through Exa's public MCP endpoint and is advertised to the model by default. To hide the tool:

```json
{
  "web_search": {
    "enabled": false
  }
}
```

For higher limits or alternate providers, add user-specific keys. Model-backed auto fallback to Perplexity/Gemini stays off unless `allow_model_providers` is true; direct provider requests still work when the matching key is configured.

```json
{
  "web_search": {
    "enabled": true,
    "provider": "auto",
    "allow_model_providers": false,
    "exa_api_key": "exa-...",
    "perplexity_api_key": "pplx-...",
    "gemini_api_key": "AIza...",
    "gemini_model": "gemini-2.5-flash",
    "perplexity_model": "sonar"
  }
}
```

Do not put shared or published API keys in this file.

## Logging and stats

Local telemetry logs are off by default. Enable logging with the master flag and each category you want:

```json
{
  "logging": {
    "enabled": true,
    "tokens": true,
    "performance": true,
    "tools": true,
    "errors": true
  }
}
```

Environment variables override config for a single run:

- `KWARD_LOGGING`
- `KWARD_LOGGING_TOKENS`
- `KWARD_LOGGING_PERFORMANCE`
- `KWARD_LOGGING_TOOLS`
- `KWARD_LOGGING_ERRORS`

Values `1`, `true`, `yes`, and `on` enable a flag. Values `0`, `false`, `no`, and `off` disable it.

Logs are JSON Lines files in `<config-dir>/logs`, usually `~/.kward/logs`. Files rotate after 10 MB using numbered suffixes, and Kward does not delete old rotated logs.

Logged data is redacted metadata only. Kward does not intentionally log prompts, assistant text, tool arguments, tool outputs, file contents, shell command text, API keys, or OAuth tokens. Logged fields can include provider/model names, token counts, byte counts, durations, retry attempts, tool names, statuses, and redacted error messages.

Use `/stats [range]` in interactive mode to summarize enabled telemetry categories. The range defaults to `1 week` and accepts values such as `5 hours`, `10 minutes`, `2 days`, or `1 year`.

Export token usage as CSV with:

```bash
kward stats tokens [range] [--bucket second|minute|hour|day|week|month|year] [--output path]
```

Example:

```bash
kward stats tokens 5 hours --bucket hour --output token-usage.csv
```

## Color output

ANSI colors are enabled automatically on TTY output.

Disable colors:

```bash
NO_COLOR=1 kward
CLICOLOR=0 kward
KWARD_COLOR=never kward
```

Force colors:

```bash
KWARD_COLOR=always kward
FORCE_COLOR=1 kward
```
