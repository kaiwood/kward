# Configuration

Prompt and skills can live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead.

Example `~/.kward/config.json`:

```json
{
  "openai_oauth_client_id": "your-client-id",
  "openai_model": "gpt-5.5",
  "openai_reasoning_effort": "medium",
  "openrouter_model": "openai/gpt-5.5"
}
```

You can also use `model` for the currently active provider model and `reasoning_effort` or `thinking_level` for OpenAI/Codex thinking level.

Overlay settings are stored under `overlay`:

```json
{
  "overlay": {
    "alignment": "center",
    "width": "capped"
  }
}
```

`alignment` can be `left`, `center`, or `right`. `width` can be `capped` for the default compact card or `maximum` to use the terminal width minus the side inset.

## Environment fallback

- Optional model env fallback: `OPENAI_ACCESS_TOKEN` or `OPENROUTER_API_KEY`.
- Optional web research env fallback: `EXA_API_KEY`, `PERPLEXITY_API_KEY`, or `GEMINI_API_KEY`.

OpenAI OAuth is used by default after login, even if `OPENROUTER_API_KEY` is set. OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the Platform API, so they use your ChatGPT account. `OPENROUTER_API_KEY` is only a fallback when no OpenAI OAuth/access token exists.

Defaults: OpenAI `gpt-5.5` with `OPENAI_REASONING_EFFORT=medium`, OpenRouter `openai/gpt-5.5`. Override with `OPENAI_MODEL`, `OPENAI_REASONING_EFFORT`, `OPENROUTER_MODEL`, or the config file values above.

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

`host` defaults to `0.0.0.0` and `port` defaults to `8765`. Kward fails to start pan mode unless `username` and `password` are configured. These credentials are stored in plaintext config, so use a user-specific password and do not share the config file.

Pan mode exposes the agent's file, shell, and web tools to anyone on the LAN who has the credentials. Use it only on trusted networks.

## Web research

Web research works without an API key through Exa's public MCP endpoint. For higher limits or alternate providers, add your own keys using environment variables or config:

```json
{
  "web_research": {
    "provider": "auto",
    "exa_api_key": "exa-...",
    "perplexity_api_key": "pplx-...",
    "gemini_api_key": "AIza...",
    "gemini_model": "gemini-2.5-flash",
    "perplexity_model": "sonar"
  }
}
```

Do not put shared or published API keys in this file. Keys are account credentials and should be user-specific.

## Color output

ANSI colors are enabled automatically on TTY output. Set `NO_COLOR=1`, `CLICOLOR=0`, or `KWARD_COLOR=never` to disable colors; set `KWARD_COLOR=always` or `FORCE_COLOR=1` to force them.
