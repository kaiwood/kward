# Usage

Kward's most common commands are:

```bash
kward                          # interactive chat
kward help                     # command overview and examples
kward "Explain this project"   # one-shot prompt
kward init                     # optional first-time setup
kward doctor                   # check local setup
kward sysprompt                # inspect the effective system prompt
kward auth status              # show saved credential status
kward pan                      # Pan mode web UI
kward rpc                      # experimental JSON-RPC backend
```

When running from source, replace `kward` with `ruby lib/main.rb`.

## Starter pack

Install Kward's starter prompts and base `PRINCIPLES.md` into your config directory, usually `~/.kward`:

```bash
kward init
```

The installer downloads the pinned `kaiwood/kward-starter-pack` `v1.0.1` release, creates the config directory and base `config.json` if needed, and copies only starter-pack instruction/prompt files. It preserves the starter-pack layout in your config directory and skips files that already exist.

## System prompt inspection

Inspect the effective system prompt Kward would use for a new conversation in the current workspace:

```bash
kward sysprompt
```

The default output is annotated with sources such as config `PRINCIPLES.md`, plugin context, skills, and workspace `AGENTS.md` handling. To print only the assembled prompt content:

```bash
kward sysprompt --raw
```

Use `--working-directory PATH` to inspect another workspace:

```bash
kward --working-directory ~/code/project sysprompt
```

Memory is not included because memory context is retrieved per user turn.

## Interactive chat

Interactive mode opens a terminal composer and saves the conversation as a per-workspace session. Use it when you want Kward to inspect files, make changes, run commands, or continue a conversation over time.

The composer stays available while assistant and tool output streams. If you press Enter while a response is still running, Kward queues your next prompt and sends it after the current turn finishes. Press Ctrl+C while a response is running to stop the current turn and return to the composer.

Kward separates the durable transcript from the provider request context. The transcript contains user, assistant, tool, and compaction messages. The current system prompt is stored as conversation runtime state and is not counted as a transcript message. For every model request, Kward builds a fresh request context from the current system prompt plus the active transcript, because supported providers are stateless across turns and need the operating instructions each time.

Persisted session files keep system prompts as audit metadata rather than transcript messages. Kward appends a `system_prompt` JSONL record when a session is attached and again only when the prompt content changes, storing the prompt content and a `sha256:` hash. This keeps normal transcript operations small while preserving enough data to inspect which operating instructions were active for model requests.

Prefix input with `!` to run a local shell command from the workspace root without sending it to the model:

```text
!git status --short
```

## Shell commands

Use `kward help` or `kward --help` to print a colored overview of available commands and examples. Use `kward help <command>` or `<command> --help` for command-specific help. Use `kward version` or `kward --version` to print the installed version.

Use `kward doctor` to check local config, workspace, auth hints, Pan credentials, and writable directories. Use `kward auth status` to show saved credential status without printing secrets, or `kward auth logout` to remove saved OpenAI, GitHub, and OpenRouter credentials.

Use `--working-directory PATH` with any mode to run Kward from a different workspace:

```bash
kward --working-directory ~/code/project
kward --working-directory ~/code/project "Summarize this project"
kward --working-directory ~/code/project pan
kward --working-directory ~/code/project rpc
```

## One-shot prompts

Command names take precedence. Invalid arguments for known commands show usage instead of becoming prompts. Anything else passed as command-line text is sent as a one-shot prompt:

```bash
kward "Summarize the changes in this repository"
kward Summarize the changes in this repository
```

Use `--` before the prompt when the prompt itself starts with a command name or contains option-like text:

```bash
kward -- pan extra
kward -- explain --working-directory option
```

Kward also accepts piped input:

```bash
git diff | kward "Review this diff"
```

One-shot prompts do not use Kward memory.

## Workspace tools

Kward can use these tools during a turn:

- `list_directory` and `read_file` to inspect the workspace.
- `write_file` and `edit_file` to create or change files.
- `run_shell_command` to run local commands from the workspace.
- `web_search` to discover live web sources.
- `fetch_content` to read specific human-readable pages after search discovery.
- `fetch_raw` to read specific machine-readable URLs such as JSON, YAML, XML, RSS, OpenAPI specs, and plain text.
- `code_search` to find packages, clone public GitHub repositories into cache, and read bounded source snippets.
- `ask_user_question` to ask structured clarification questions.

Safety rules:

- Existing files must be read in the current conversation before Kward can write or edit them.
- Text file reads and edits are capped at 256 KiB per file.
- Tool schemas are the official contract for generated tool calls and returned tool payloads.
- At runtime, Kward accepts tolerant incoming tool-call input for compatibility: extra fields are ignored, and existing legacy-compatible input shapes remain supported.
- Required fields and invalid required values still return explicit tool errors.
- Tool output payloads are kept schema-clean so future model calls and restored transcripts do not depend on accidental extra fields.
- When successful tool results include unified diffs, the composer status shows live session totals such as `+700|-572`.

## Slash commands

Use slash commands in interactive mode for local Kward actions:

| Command | Purpose |
| --- | --- |
| `/exit`, `/quit` | Leave the session. |
| `/new` | Start a fresh session. |
| `/resume [path]` | Resume a saved session, or pick one when no path is given. |
| `/name [name]` | Name or clear the current session name. |
| `/clone` | Duplicate the current session. |
| `/copy [last\|transcript]` | Copy clean assistant text or the Markdown transcript to the clipboard. |
| `/export [path]` | Export the transcript as Markdown. |
| `/compact [instructions]` | Summarize older conversation into a checkpoint and keep recent context. |
| `/model` | Choose or type the default model. |
| `/openrouter/catalog` | List the full OpenRouter model catalog. |
| `/reasoning` | Choose reasoning effort. |
| `/settings` | Configure overlay alignment and width. |
| `/login` | Log in from inside the session. |
| `/status` | Show status and auto-compaction information. |
| `/stats [range]` | Show local telemetry stats when logging is enabled. |
| `/memory ...` | Manage opt-in memory. |
| `/redraw` | Refresh the terminal after resize or drawing glitches. |

Prompt templates can add more slash commands. Plugin commands can also appear when trusted local plugins are installed.

## Sessions

Interactive chats are stored as JSONL files under `~/.kward/sessions/`. Sessions are per workspace.

Useful session commands:

- `/resume` opens a picker for recent sessions.
- `/name <name>` gives the current session a human-readable name.
- `/clone` creates a new independent copy. Cloned sessions remember their parent and appear in the recent session picker by modification time.
- `/copy` and `/copy last` copy the latest assistant response without terminal borders or ANSI styling. `/copy transcript` copies the clean Markdown transcript. Mouse selection may still include terminal UI chrome.
- `/export [path]` writes a Markdown transcript. Explicit paths are resolved relative to the current workspace and must stay inside the workspace or Kward session directory.
- `/compact [instructions]` summarizes older conversation into a structured Ruby-aware checkpoint. Text after `/compact ` is freeform focus text, not parsed as flags.

After compaction, Kward may need to re-read files before future edits because compacting clears remembered read-file state.

## Auto-compaction

Auto-compaction is enabled by default when Kward can determine the active context window. It reserves part of the model context so conversations can continue longer without suddenly exceeding the limit.

Configure it in `config.json`:

```json
{
  "compaction": {
    "enabled": true,
    "reserve_tokens": 16384,
    "keep_recent_tokens": 20000
  }
}
```

Manual `/compact` still works when auto-compaction is disabled.

## Memory

Memory is disabled by default and only applies to interactive sessions.

Common commands:

```text
/memory enable
/memory core <text>
/memory add <text>
/memory list
/memory why
/memory promote <id>
/memory relax <id>
/memory forget <id>
/memory disable
```

See [Memory](memory.md) for storage locations, safety rules, auto-summary, and RPC methods.

## Composer keys

- Enter sends.
- Shift+Enter inserts a newline.
- Up/Down browse prompt history.
- Ctrl+D exits from an empty prompt.
- Ctrl+C stops the current response while assistant or tool output is running.
- Backspace at the beginning of the prompt removes the most recent image attachment.

Multiline input grows the composer up to a capped height.

## Image attachments

Kward can attach images when the active model supports images. It detects:

- pasted image file paths,
- Markdown image links,
- `file://` image URLs,
- image data URLs.

In the interactive composer, pasted image references appear as attachment badges instead of editable filename or base64 text. Transcripts show attachment badges and render the image inline when the terminal advertises a supported inline image protocol, such as iTerm2 or Kitty/WezTerm.

## Pan mode

Pan mode starts a minimal LAN web UI with a prompt textarea and transcript:

```bash
kward --working-directory="/path/to/workspace" pan
```

From source:

```bash
ruby lib/main.rb --working-directory="/path/to/workspace" pan
```

Pan mode streams assistant output and tool calls, queues prompts submitted while a turn is running, and saves the conversation as a normal per-workspace session.

Configure `pan_mode.username` and `pan_mode.password` before starting it; see [Configuration](configuration.md). Pan mode is reachable on the LAN, so use it only on trusted networks.
