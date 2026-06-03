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

## Environment fallback

- Optional env fallback: `OPENAI_ACCESS_TOKEN` or `OPENROUTER_API_KEY`.

OpenAI OAuth is used by default after login, even if `OPENROUTER_API_KEY` is set. OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the Platform API, so they use your ChatGPT account. `OPENROUTER_API_KEY` is only a fallback when no OpenAI OAuth/access token exists.

Defaults: OpenAI `gpt-5.5` with `OPENAI_REASONING_EFFORT=medium`, OpenRouter `openai/gpt-5.5`. Override with `OPENAI_MODEL`, `OPENAI_REASONING_EFFORT`, `OPENROUTER_MODEL`, or the config file values above.

## Color output

ANSI colors are enabled automatically on TTY output. Set `NO_COLOR=1`, `CLICOLOR=0`, or `KWARD_COLOR=never` to disable colors; set `KWARD_COLOR=always` or `FORCE_COLOR=1` to force them.
