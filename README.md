# Ruby CLI Agent

Minimal CLI coding agent using OpenRouter or OpenAI.

## Getting started

```bash
bundle install
ruby lib/main.rb login                   # sign in with OpenAI OAuth
ruby lib/main.rb                         # start a multi-turn chat
ruby lib/main.rb "Explain this Ruby file" # single prompt
ruby test/test_main.rb
```

In chat mode, the agent waits at `You>` until you ask something. It can inspect the workspace with `list_directory` and `read_file`, and safely write files with `write_file`. Existing files must be read in the current conversation before writing, and every write asks for confirmation first. Type `/exit` or `/quit` to leave.

Auth options:

- OpenAI OAuth: put `openai_oauth_client_id` in `~/.kward/config.json`, then run `ruby lib/main.rb login` and complete the browser redirect flow. OAuth tokens are saved to `~/.kward/auth.json` with file mode `0600`.

Example `~/.kward/config.json`:

```json
{
  "openai_oauth_client_id": "your-client-id"
}
```
- Optional env fallback: `OPENAI_ACCESS_TOKEN` or `OPENROUTER_API_KEY`.

OpenAI OAuth is used by default after login, even if `OPENROUTER_API_KEY` is set. OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the Platform API, so they use your ChatGPT account. `OPENROUTER_API_KEY` is only a fallback when no OpenAI OAuth/access token exists. Defaults: OpenAI `gpt-5.5` with `OPENAI_REASONING_EFFORT=medium`, OpenRouter `openai/gpt-5.5`. Override with `OPENAI_MODEL`, `OPENAI_REASONING_EFFORT`, or `OPENROUTER_MODEL`.
