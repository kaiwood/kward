# Configuration

Kward reads user configuration from `~/.kward/config.json` by default. Most users do not need to edit this file by hand at first: use `/login`, `/model`, `/reasoning`, and `/settings` from inside Kward when possible.

On first start, if the file does not exist, Kward creates a starter config with an active Kward persona, explicit disabled memory settings, and the default composer busy-help setting so you can inspect and edit them. Provider-specific model defaults are added only when you choose a provider/model. See [Personas](personas.md) for configuring persona selection by workspace, model, or reasoning effort. If `KWARD_CONFIG_PATH` is set, Kward uses that file instead and treats that file's directory as the config directory for prompts, skills, memory, logs, and caches.

Small examples:

```json
{
  "provider": "openrouter",
  "openrouter_model": "openai/gpt-5.5"
}
```

```json
{
  "mcpServers": {
    "safari": {
      "command": "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver",
      "args": ["--mcp"]
    }
  }
}
```

See [MCP servers](mcp.md) for connecting local Model Context Protocol servers such as Safari's browser automation server.

```json
{
  "skills": {
    "trust_project": true
  }
}
```

By default, Kward loads user-level skills but skips project-level skills from the workspace. Set `skills.trust_project` to `true`, or use `/settings` → `Tools & Search` → `Trust project skills`, when you trust the repository's `.kward/skills` or `.agents/skills` directories. See [Extensibility](extensibility.md) for skill locations and examples.

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
~/.kward/anthropic_auth.json
~/.kward/github_auth.json
~/.kward/sessions/
~/.kward/memory/
~/.kward/logs/
~/.kward/cache/
~/.kward/plugins/
```

When `KWARD_CONFIG_PATH=/path/to/config.json` is set, most config-related files live beside that file instead. User plugins are the exception: they are loaded only from `~/.kward/plugins`. See [Plugins](plugins.md) for writing and loading user plugins.

## Embedded shell config

The embedded Kward shell (`/shell`, internally `ekwsh`) reads optional global settings from `~/.kward/ekwsh.yml` or, when `KWARD_CONFIG_PATH` is set, from `ekwsh.yml` beside that config file.

Example:

```yaml
env:
  FORCE_COLOR: "1"
  CLICOLOR_FORCE: "1"

aliases:
  ll: "ls -la"
  gs: "git status --short"
  gd: "git diff --color=always"
```

`env` values are applied when shell mode starts, after Kward's conservative color defaults. Keys must look like environment variable names (`A_Z`, digits after the first character, and underscores); invalid keys are ignored. Values are converted to strings.

`aliases` expand the first word of a command once. For example, `ll lib` runs `ls -la lib`. Built-in `ekwsh` commands such as `cd`, `pwd`, `export`, `unset`, `alias`, `clear`, `pty`, and `exit` take precedence over aliases. Run `alias` inside `ekwsh` to list configured aliases. Aliases are also included in command-name Tab completion.

## Provider and model settings

Set `provider` to choose the active backend:

```json
{
  "provider": "codex"
}
```

When `provider` is unset, Kward infers the backend from available credentials, defaulting to OpenAI/Codex when OAuth credentials are present. Set `provider` or `KWARD_PROVIDER` to select another backend explicitly.

Supported values are:

- `codex` for the OpenAI/ChatGPT Codex backend.
- `anthropic` for Anthropic Claude Pro/Max subscription support.
- `openrouter` for OpenRouter.
- `copilot` for experimental Copilot provider support.

Model settings:

```json
{
  "model": "gpt-5.5",
  "openai_model": "gpt-5.5",
  "openrouter_model": "openai/gpt-5.5",
  "anthropic_model": "claude-sonnet-4-5",
  "copilot_model": "gpt-5-mini",
  "reasoning_effort": "medium",
  "openai_reasoning_effort": "medium",
  "openrouter_reasoning_effort": "medium",
  "anthropic_reasoning_effort": "medium",
  "copilot_reasoning_effort": "medium",
  "thinking_level": "medium"
}
```

`model` is a generic setting for the active provider. Provider-specific values such as `openai_model`, `anthropic_model`, `openrouter_model`, and `copilot_model` take precedence for their provider. `reasoning_effort` and `thinking_level` are generic reasoning settings. `thinking_level` is an alias for `reasoning_effort` honored by all providers. For each provider, Kward resolves reasoning in this order: the provider-specific key (for example `openai_reasoning_effort`), then the generic `reasoning_effort`, then `thinking_level`, then the default `medium`. `openai_reasoning_effort`, `anthropic_reasoning_effort`, `openrouter_reasoning_effort`, and `copilot_reasoning_effort` are provider-specific forms.

Defaults:

- OpenAI/Codex: `gpt-5.5`
- OpenRouter: `openai/gpt-5.5`
- Anthropic: `claude-sonnet-4-5`
- Copilot: `gpt-5-mini`
- Reasoning effort: `medium`

The interactive `/model` picker reads cached OpenRouter models when available. Run `kward openrouter refresh` to fetch text-capable models available to the configured OpenRouter API key and cache them under `~/.kward/cache/openrouter_models.json`. Run `kward openrouter list` to inspect the cached model ids.

## Environment overrides

Use environment variables for one-off runs or local secrets that you do not want in config.

Provider and model:

- `KWARD_PROVIDER`
- `OPENAI_MODEL`
- `OPENAI_REASONING_EFFORT`
- `OPENROUTER_MODEL`
- `OPENROUTER_REASONING_EFFORT`
- `ANTHROPIC_MODEL`
- `ANTHROPIC_REASONING_EFFORT`
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

Use environment variables for temporary or local-only secrets when possible. If multiple credentials are available, OpenAI OAuth is used by default unless `provider` or `KWARD_PROVIDER` selects another backend such as `anthropic`, `openrouter`, or `copilot`.

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

In the normal composer prompt, `Tab` cycles forward through the current model's reasoning efforts and `Shift+Tab` cycles backward. The shortcuts wrap around and update the persisted reasoning setting; file and slash-command completion overlays keep their existing `Tab` completion behavior.

`tab_keybindings` controls how the composer handles tab navigation shortcuts:

```json
{
  "composer": {
    "tab_keybindings": "auto"
  }
}
```

`auto` (default) detects terminal support, `ctrl` uses `Ctrl+Tab`/`Shift+Tab` to cycle suggestions and indent, `alt` uses `Alt+Tab` for terminals where `Ctrl+Tab` is swallowed.

## Editor settings

The built-in TUI file editor supports three keybinding modes. Modern is the default:

```json
{
  "editor": {
    "mode": "modern"
  }
}
```

`mode` can be `modern`, `emacs`, or `vibe`. The old `default` value is still accepted as an alias for `modern`. You can change this from `/settings` > Interface > Editor mode; newly opened editor buffers pick up the setting immediately.

The editor automatically highlights Ruby, Crystal, Elixir, Julia, JavaScript, TypeScript, JSON, Markdown, YAML, Shell, Makefile, HTML, CSS, SCSS, Python, Go, Rust, Java, C#, C, C++, Swift, Kotlin, Lua, and SQL files when terminal color is enabled. Unknown file types and color-disabled terminals render plain text.

Auto-indent is enabled by default. Pressing Enter copies the current line indentation, detects the file's indentation unit when possible, and applies lightweight syntax-based indentation for recognized file types. For Ruby, Crystal, Elixir, Julia, Lua, Makefiles, and shell scripts, Enter after a block opener inserts the matching closing keyword, and Ctrl+Enter can force that behavior from the middle of the line in terminals that report modified Enter keys. When auto-indent is enabled, typing obvious closing tokens such as `}`, Ruby/Lua `end`, and shell `fi`/`done`/`esac` re-indents the current line, and Backspace in leading indentation removes one detected indentation unit. To disable it:

```json
{
  "editor": {
    "auto_indent": false,
    "auto_close_pairs": false
  }
}
```

`auto_indent` and `auto_close_pairs` both default to `true`. Set `auto_close_pairs` to `false` to disable automatic insertion of matching `()`, `[]`, `{}`, quotes, and backticks.

Line numbers are absolute by default. Set `line_numbers` to `relative` to show distances from the cursor line in editable buffers while keeping the current cursor line absolute:

```json
{
  "editor": {
    "line_numbers": "relative"
  }
}
```

Soft-wrap is enabled by default so long lines wrap within the editor width instead of scrolling. To disable it:

```json
{
  "editor": {
    "soft_wrap": false
  }
}
```

Editable editor buffers request a vertical bar cursor by default. Terminals that do not support cursor-shape escape sequences ignore this. To keep the terminal's normal cursor shape while editing:

```json
{
  "editor": {
    "bar_cursor": false
  }
}
```

Modern mode uses composer-style keys: `Ctrl+S` saves, `Ctrl+Q` quits, `Ctrl+F` searches, Shift+Arrow selects text, `Ctrl+C` copies, `Ctrl+X` cuts, `Ctrl+V` pastes the editor kill buffer, `Ctrl+A`/`Ctrl+E` move to the start/end of the line, `Ctrl+B` moves left, `Ctrl+K` kills to end of line, `Ctrl+U` kills to start of line, and `Alt+B`/`Alt+F` move by word.

Emacs mode uses Emacs-style non-modal keys: `Ctrl+X Ctrl+S` saves, `Ctrl+X Ctrl+C` quits, `Ctrl+S` searches forward, `Ctrl+R` searches backward, `Ctrl+Space` sets the mark, `Ctrl+W` kills the region or previous word, `Alt+W` copies the region, `Ctrl+K` kills to end of line, `Ctrl+Y` yanks, and `Alt+Y` cycles the per-buffer kill ring after a yank.

Vibe mode opens files in normal mode and supports a compact Vim-style subset: normal/insert/command modes, character, line, and block visual modes, `h/j/k/l`, word and WORD movement, counts, `d`/`y`/`c` operators, line yanks and indentation, case operators, marks, macros, jump-list navigation, linewise paste, search, undo/redo, and common `:w`, `:q`, `:q!`, `:wq`, `:x`, `:e`, substitution, and `:number` commands. Yanks also copy to the terminal clipboard when OSC 52 is supported.

## Session settings

Interactive CLI and RPC clients start fresh by default. To automatically resume the last active session for the current workspace:

```json
{
  "sessions": {
    "auto_resume": true
  }
}
```

The `/sessions` command, `/resume` alias, and RPC `sessions/resume` work regardless of this automatic resume setting.

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

`kward pan` starts a LAN-reachable web UI and requires HTTP Basic Auth. Configure credentials before starting it:

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

## Global principles

Put global engineering principles in `PRINCIPLES.md` beside your config file, usually `~/.kward/PRINCIPLES.md`. Kward appends this file to its built-in system instructions when present. Existing config-directory `AGENTS.md` files are still read as a legacy alias when `PRINCIPLES.md` is absent.

## Workspace AGENTS.md

By default, Kward does not inject the full workspace `AGENTS.md` into every request. When a workspace `AGENTS.md` exists, Kward injects a compact instruction telling the model to read it for repository-related tasks before analyzing or modifying project files.

For smaller models that need the workspace instructions in the initial system prompt, enforce direct injection:

```json
{
  "enforce_workspace_agents_file": true
}
```

The default is `false`.

## Tool workspace guardrails

Workspace guardrails are enabled by default. File tools such as `read_file`, `write_file`, `edit_file`, and `list_directory` are limited to the active workspace. To allow those file tools to access paths outside the workspace:

```json
{
  "tools": {
    "workspace_guardrails": false
  }
}
```

This is not a sandbox setting. Shell commands already run as your OS user from the workspace directory and can access anything that user can access.

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
