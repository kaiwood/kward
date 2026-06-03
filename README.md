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

In chat mode, the agent shows a boxed bottom composer. It can inspect the workspace with `list_directory` and `read_file`, safely write files with `write_file`, edit existing files with `edit_file`, run shell commands with `run_shell_command` after confirmation, and search the web with `web_research`. Existing files must be read in the current conversation before writing or editing, and every write asks for confirmation first. Type `/exit` or `/quit` to leave.

Composer keys: Enter sends, Shift+Enter inserts a newline, Up/Down browse prompt history, Ctrl+D exits an empty prompt. Use `/redraw` to refresh the visible terminal after resize glitches. While assistant/tool output is streaming, the composer stays pinned and editable; pressing Enter queues the next prompt and sends it after the current response finishes. Multiline input grows the composer up to a capped height. Pasted image file paths, Markdown image links, file:// image URLs, and image data URLs are attached to the prompt when the active model supports images.

ANSI colors are enabled automatically on TTY output. Set `NO_COLOR=1`, `CLICOLOR=0`, or `KWARD_COLOR=never` to disable colors; set `KWARD_COLOR=always` or `FORCE_COLOR=1` to force them.

Web research uses no API key by default. It tries DuckDuckGo HTML search first, then bundled public SearXNG instances as fallback. Queries are sent over the network to those services.

Auth options:

- OpenAI OAuth: put `openai_oauth_client_id` in `~/.kward/config.json`, then run `ruby lib/main.rb login` and complete the browser redirect flow. OAuth tokens are saved to `~/.kward/auth.json` with file mode `0600`.

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

Prompt and skills can live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead.

- `AGENTS.md`: appended to Kward's built-in system instructions when present.
- `skills/<skill-name>/SKILL.md`: listed in the system instructions by frontmatter `name` and `description`. The assistant can call `read_skill` to load `SKILL.md` or related files inside that skill folder.

Example skill:

```markdown
---
name: planner
description: Helps plan implementation work.
---

# Planner

Use this when planning a code change.
```

- Optional env fallback: `OPENAI_ACCESS_TOKEN` or `OPENROUTER_API_KEY`.

OpenAI OAuth is used by default after login, even if `OPENROUTER_API_KEY` is set. OAuth requests go to the ChatGPT/Codex backend (`chatgpt.com/backend-api/codex/responses`), not the Platform API, so they use your ChatGPT account. `OPENROUTER_API_KEY` is only a fallback when no OpenAI OAuth/access token exists. Defaults: OpenAI `gpt-5.5` with `OPENAI_REASONING_EFFORT=medium`, OpenRouter `openai/gpt-5.5`. Override with `OPENAI_MODEL`, `OPENAI_REASONING_EFFORT`, `OPENROUTER_MODEL`, or the config file values above.
