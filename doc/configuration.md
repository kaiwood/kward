# Configuration

Kward reads user configuration from `~/.kward/config.json` by default. Most users should start with `/settings`, `/login`, `/model`, or `/reasoning` inside Kward. Edit JSON directly when you need an advanced setting, an integration, or a reproducible configuration.

On first start, Kward creates the file when it does not exist. The starter config records defaults for personas, memory, the composer, editor, overlays, web search, update checks, sessions, skills, MCP, and workspace guardrails. Provider-specific model defaults are added only when you choose a provider or model.

If `KWARD_CONFIG_PATH` is set, Kward uses that file and treats its directory as the config directory for prompts, skills, memory, logs, and caches.

## Choose a configuration path

Use the interactive controls for ordinary changes. Edit `config.json` when you need a setting that is not exposed there or when you want to share a reproducible setup.

| Goal | Recommended path |
| --- | --- |
| Sign in or change accounts | `/settings` → Accounts, or `/login` |
| Choose a provider, model, or reasoning effort | `/settings` → Model & Reasoning, `/model`, or `/reasoning` |
| Change editor, diff, overlay, or session UI behavior | `/settings` → Interface |
| Enable memory | `/settings` → Memory |
| Configure web search or trust project skills | `/settings` → Tools & Search |
| Contain model-requested shell commands | `/sandbox` for mode and child-network access; edit config for additional writable roots |
| Tune compaction | `/settings` → Context & Compaction |
| Configure personas | `/settings` → Personalization; see [Personas](personas.md) |
| Add MCP servers, lifecycle hooks, or environment-specific paths | Edit `config.json` directly |

For the complete reference, jump to [providers and models](#Provider_and_model_settings), [terminal interface settings](#Overlay_settings), [sessions and memory](#Session_settings), [web search](#Web_search), [workspace safety](#Tool_workspace_guardrails), or [logging](#Logging_and_stats).

Here is a minimal direct provider configuration:

```json
{
  "provider": "openrouter",
  "openrouter_model": "openai/gpt-5.6-sol"
}
```

### MCP servers

Add trusted local Model Context Protocol servers under `mcpServers`:

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

See [MCP servers](mcp.md) for setup, supported fields, and security notes.

### Transport plugins

Transport plugin settings live under `transports` and are scoped by the
transport's stable ID:

```json
{
  "transports": {
    "com.kward.telegram": {
      "workspace": "/Users/me/src/project",
      "allowed_user_ids": [123456789],
      "allowed_chat_ids": [123456789],
      "poll_timeout_seconds": 25
    }
  }
}
```

Transport plugins are trusted local Ruby code. Keep credentials in environment
variables or another private secret mechanism provided by the plugin rather
than committing them to `config.json`. Transport state, including external
conversation bindings and idempotency keys, is stored privately under the
transport's namespace in `~/.kward/transports/`.

Run `kward transport list` to inspect registrations, `kward transport status`
to inspect runtime state, and `kward transport run NAME` to run a transport in
the foreground. See [Telegram transport](telegram.md) for the first-party
long-polling adapter and setup instructions.

### Project skills

Kward loads user-level skills but skips project-level skills by default. Enable them only for repositories you trust, either through `/settings` → Tools & Search → Trust project skills or with:

```json
{
  "skills": {
    "trust_project": true
  }
}
```

See [Skills](skills.md) for skill locations, precedence, examples, and trust behavior.

### Update checks

Kward checks RubyGems for newer versions on the interactive startup screen. Results are cached so startup does not contact RubyGems every time. Disable this automatic network request with:

```json
{
  "updates": {
    "check": false
  }
}
```

You can also set `KWARD_DISABLE_UPDATE_CHECK=1` for one run. The cache lives at `<config-dir>/cache/update_check.json`.

## Config directory

By default, Kward stores user data under `~/.kward`. Common files and directories include:

```text
~/.kward/config.json
~/.kward/auth.json
~/.kward/anthropic_auth.json
~/.kward/github_auth.json
~/.kward/PRINCIPLES.md
~/.kward/ekwsh.yml
~/.kward/prompts/
~/.kward/skills/
~/.kward/plugins/
~/.kward/sessions/
~/.kward/history/
~/.kward/memory/
~/.kward/logs/
~/.kward/cache/
~/.kward/trusted_workspace_hooks.json
```

When `KWARD_CONFIG_PATH=/path/to/config.json` is set, most config-related files live beside that file instead. User plugins are the exception: they are loaded only from `~/.kward/plugins`. See [Plugins](plugins.md) for writing and loading user plugins.

## Lifecycle hooks

Configure command or HTTP lifecycle hooks with a top-level `hooks` object. Each key is an event name and each value is an array of hook entries. Command hooks receive event JSON on stdin and return decision JSON on stdout. HTTP hooks receive event JSON by `POST` and return decision JSON in the response body.

```json
{
  "hooks": {
    "shell_command_before": [
      {
        "id": "block-release",
        "type": "command",
        "command": "~/.kward/hooks/block-release.rb",
        "timeout_seconds": 5,
        "failure_policy": "deny",
        "match": { "command_regex": "\\bgem push\\b" }
      }
    ]
  }
}
```

Use `failure_policy` (`allow`, `warn`, `deny`, or `ask`) to decide what happens if the hook command fails, times out, or returns invalid JSON.

Project-local hooks can also live in `.kward/hooks.json`, but Kward loads them only after you explicitly run `/hooks trust` in that workspace. Trust is tied to the file digest, so changes require re-trusting. See [Lifecycle hooks](lifecycle-hooks.md) for events, decisions, selectors, plugin hooks, command-hook protocol, workspace trust, and security notes.

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
- `copilot` for Copilot provider support.
- `local` for an OpenAI-compatible Ollama, LM Studio, or llama.cpp server. See [Local models](local-models.md).

Model settings:

```json
{
  "model": "gpt-5.6-sol",
  "openai_model": "gpt-5.6-sol",
  "openrouter_model": "openai/gpt-5.6-sol",
  "anthropic_model": "claude-sonnet-5",
  "copilot_model": "gpt-5-mini",
  "local_model": "qwen2.5-coder:7b",
  "reasoning_effort": "medium",
  "openai_reasoning_effort": "medium",
  "openrouter_reasoning_effort": "medium",
  "anthropic_reasoning_effort": "medium",
  "copilot_reasoning_effort": "medium",
  "thinking_level": "medium"
}
```

`model` is a generic setting for the active provider. Provider-specific values such as `openai_model`, `anthropic_model`, `openrouter_model`, and `copilot_model` take precedence for their provider. `reasoning_effort` and `thinking_level` are generic reasoning settings. `thinking_level` is an alias for `reasoning_effort` honored by all providers. For each provider, Kward resolves reasoning in this order: the provider-specific key (for example `openai_reasoning_effort`), then the generic `reasoning_effort`, then `thinking_level`, then the default `medium`. `openai_reasoning_effort`, `anthropic_reasoning_effort`, `openrouter_reasoning_effort`, and `copilot_reasoning_effort` are provider-specific forms.

Set `codex_show_raw_reasoning` to `true` to display raw Codex `reasoning_text` when the API does not provide reasoning summary text. It defaults to `false`; raw reasoning can include internal or unstable model output, so enable it only when you explicitly want to inspect that stream.

`stream_idle_timeout_seconds` limits how long a streamed Codex, Anthropic, or Local response may go without receiving data. It defaults to `120`; set a positive value to override it. When the provider is silent longer than this limit, Kward closes the request and applies its normal transient-network retry behavior.

Defaults:

- OpenAI/Codex: `gpt-5.6-sol`
- OpenRouter: `openai/gpt-5.6-sol`
- Anthropic: `claude-sonnet-5`
- Copilot: `gpt-5-mini`
- Reasoning effort: `medium`

The Anthropic model choices include `claude-fable-5`, but Fable availability depends on the logged-in account and organization. Selecting it without access returns an Anthropic provider error.

The interactive `/model` picker reads cached OpenRouter models when available. Run `kward openrouter refresh` to fetch text-capable models available to the configured OpenRouter API key and cache them under `~/.kward/cache/openrouter_models.json`. Run `kward openrouter list` to inspect the cached model ids.

### Local model server

The `local` provider uses OpenAI-compatible Chat Completions and model-list endpoints. Configure a running local server with a model id and its actual context window:

```json
{
  "provider": "local",
  "local_backend": "ollama",
  "local_base_url": "http://127.0.0.1:11434/v1",
  "local_model": "qwen2.5-coder:7b",
  "local_context_window": 32768
}
```

`local_backend` selects a convenience default: `ollama`, `lm_studio`, or `llama_cpp`. Their default base URLs are `http://127.0.0.1:11434/v1`, `http://127.0.0.1:1234/v1`, and `http://127.0.0.1:8080/v1`, respectively. Set `local_base_url` to use a custom endpoint. `local_api_key` is optional and is sent as a bearer token only when configured.

Set `local_context_window` to the context length configured for the loaded model. Kward does not infer this safely from an arbitrary local model name; without it, automatic context budgeting cannot report a reliable limit. Local providers do not expose Kward reasoning or image controls by default.

## Environment overrides

Use environment variables for one-off runs or local secrets that you do not want in config.

Provider and model:

- `KWARD_PROVIDER`
- `OPENAI_MODEL`
- `OPENAI_REASONING_EFFORT`
- `OPENROUTER_MODEL`
- `OPENROUTER_REASONING_EFFORT`
- `KWARD_LOCAL_BACKEND`
- `KWARD_LOCAL_BASE_URL`
- `KWARD_LOCAL_MODEL`
- `KWARD_LOCAL_CONTEXT_WINDOW`
- `KWARD_LOCAL_API_KEY`
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

Overlay settings control terminal picker/card layout. New default configs include this section, and partial existing configs use the same defaults for missing keys:

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

<a id="project-browser-icons"></a>
## Project browser icons

`/files` uses text-only rows by default so it remains legible in terminals without a patched icon font. To enable Nerd Font icons explicitly:

```json
{
  "project_browser": {
    "icons": "nerd-font"
  }
}
```

`icons` defaults to `off`; the supported values are `off` and `nerd-font`. Kward does not detect terminal fonts. Enable `nerd-font` only after configuring a compatible Nerd Font, such as Hack Nerd Font, in your terminal. You can also select **File icons** under the Interface section of `/settings`.

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

`mode` can be `modern`, `emacs`, or `vibe`. The old `default` value is still accepted as an alias for `modern`. You can change this from `/settings` → Interface → Editor mode; newly opened editor buffers pick up the setting immediately.

The integrated Git and session diff viewers support unified and side-by-side layouts:

```json
{
  "editor": {
    "diff_view": "auto"
  }
}
```

`diff_view` can be `auto`, `unified`, or `side_by_side`. In `auto` mode, Kward uses side-by-side output when the terminal is at least 120 columns wide and unified output in narrower terminals. Change it with `/settings` → Interface → Diff view.

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

The `/session` command, `/resume` alias, and RPC `sessions/resume` work regardless of this automatic resume setting.

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

These credentials are stored in plaintext config. Use a private, user-specific password and do not share the config file. Pan mode exposes the agent's file, shell, web, and configured extension tools to anyone on the LAN who has the credentials, so use it only on trusted networks. See [Pan mode](pan.md) for the full browser workflow, session behavior, security guidance, and limitations.

## Web search

Web search is enabled by default with automatic provider selection. Model-backed fallback providers remain disabled unless you explicitly allow them:

```json
{
  "web_search": {
    "enabled": true,
    "provider": "auto",
    "allow_model_providers": false
  }
}
```

Existing configs without a `web_search` object use those same defaults. Web search works without an API key through Exa's public MCP endpoint and is advertised to the model by default. To hide the tool:

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

## Replacement system prompt

Set `system_prompt.file` to use a file as the entire system prompt. In replacement mode Kward does not append its built-in instructions, global principles, memory context, personas, plugin context, skills, or workspace `AGENTS.md` guidance.

```json
{
  "system_prompt": {
    "file": "prompts/local-minimal.md",
    "include_principles": false
  }
}
```

Relative paths are resolved beside `config.json`. The file is sent to the configured model and can be recorded in session prompt snapshots, so do not place secrets in it. Use `kward sysprompt` to inspect the exact active prompt.

To retain Kward's normal prompt while omitting only global `PRINCIPLES.md` (and its legacy config-directory `AGENTS.md` fallback), configure:

```json
{
  "system_prompt": {
    "include_principles": false
  }
}
```

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

Workspace guardrails limit Kward file tools; they are not an operating-system sandbox and do not constrain arbitrary shell commands. See [Command sandboxing](sandboxing.md) to apply an opt-in operating-system boundary to model-requested `run_shell_command` workers.

## Command sandboxing

Sandboxing is off by default. Use `/sandbox` to inspect or change the mode and child-network access. For additional writable roots or Git metadata protection, edit the `sandbox` config directly. `sandbox.mode` accepts `off`, `read_only`, or `workspace_write`; `sandbox.network` defaults to `deny`, and `sandbox.protect_git_metadata` defaults to `true`.

```json
{
  "sandbox": {
    "mode": "workspace_write",
    "network": "deny"
  }
}
```

When Kward cannot enforce a requested non-off mode, it denies the command rather than running it unrestricted. Current support and limits are documented in [Command sandboxing](sandboxing.md).

## Permissions

Permissions are off by default. When enabled, the permission policy decides whether a model-requested tool can start. It is not an operating-system sandbox: permitted shell commands still run with your user account's access.

```json
{
  "permissions": {
    "enabled": true,
    "mode": "ask"
  }
}
```

Available modes are:

| Mode | Behavior |
| --- | --- |
| `ask` | Read-only tools run normally; file changes, shell commands, web tools, and MCP tools need approval. |
| `workspace-write` | File changes within `write_scopes` run without approval; shell and network tools still need approval. |
| `read-only` | Denies file changes, shell commands, web tools, and MCP tools. |
| `deny-by-default` | Denies risky tools unless an `allow` rule matches. |

`allow`, `ask`, and `deny` rules are arrays of objects matching `tool`, `path`, `host`, `command`, or `source`. Deny rules always take precedence, then ask, then allow. Use `write_scopes` to restrict writes in `workspace-write` mode:

```json
{
  "permissions": {
    "enabled": true,
    "mode": "workspace-write",
    "write_scopes": ["lib/**", "test/**"],
    "deny": [{ "tool": "run_shell_command", "command": "git push*" }]
  }
}
```

The interactive CLI presents an approval overlay for an `ask` decision. RPC clients can use their existing `approvalMode: "ask"` bridge. Frontends without an approval bridge, including Pan, fail closed for policy approvals.

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
