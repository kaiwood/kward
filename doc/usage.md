# Usage

In chat mode, the agent shows a boxed bottom composer. It can inspect the workspace with `list_directory` and `read_file`, safely write files with `write_file`, edit existing files with `edit_file`, run shell commands with `run_shell_command` after confirmation, search the web with `web_search`, discover and read cached open-source repositories with `code_search`, and ask structured clarification questions with `ask_user_question`.

Existing files must be read in the current conversation before writing or editing, and every write asks for confirmation first. Text file reads and edits are capped at 256 KiB per file to avoid accidentally loading very large files into context.

## Pan mode

Start a minimal LAN web UI with:

```bash
ruby lib/main.rb --pan-mode --working-directory="/path/to/workspace"
```

Pan mode serves a single authenticated page with a prompt textarea and transcript. It streams assistant output and tool calls, queues prompts submitted while a turn is running, and saves the conversation as a normal per-workspace session. Configure `pan_mode.username` and `pan_mode.password` first; see [Configuration](configuration.md).

## Sessions

Interactive chats are saved as per-workspace JSONL sessions under `~/.kward/sessions/`. Type `/exit` or `/quit` to leave.

Use `/new` to start fresh, `/resume` to pick a saved session, `/name <name>` to name the current session, `/clone` to duplicate it, `/export [path]` to write a Markdown transcript, `/compact [instructions]` to summarize older conversation into a structured Ruby-aware checkpoint while preserving recent messages, `/model` to choose or type a default model, `/reasoning` to choose reasoning effort, `/settings` to configure overlay alignment and width, and `/redraw` to refresh the visible terminal after resize glitches. Cloned sessions remember their parent and appear indented under it in the `/resume` picker. Text after `/compact ` is freeform focus text, not parsed as flags. After compaction, files may need to be re-read before future edits.

Auto-compaction is enabled by default when Kward can determine the active context window. Configure it in `config.json` with `compaction.enabled`, `compaction.reserve_tokens`, and `compaction.keep_recent_tokens`; manual `/compact` still works when auto-compaction is disabled.

## Memory

Memory is disabled by default and only applies to interactive sessions. Use `/memory enable` to opt in, `/memory core <text>` for explicit high-trust memories, `/memory add <text>` for contextual soft memories, `/memory list` to inspect stored memories, `/memory why` to explain the most recent retrieval, and `/memory forget <id>` to remove a memory. See [Memory](memory.md) for storage locations, safety rules, and RPC methods.

## Composer keys

- Enter sends.
- Shift+Enter inserts a newline.
- Up/Down browse prompt history.
- Ctrl+D exits an empty prompt.

While assistant/tool output is streaming, the composer stays pinned and editable; pressing Enter queues the next prompt and sends it after the current response finishes. When successful tool results include unified diffs, the composer status shows live session totals like `+700|-572` to the left of the context percentage. Multiline input grows the composer up to a capped height.

## Image attachments

Pasted image file paths, Markdown image links, file:// image URLs, and image data URLs are attached to the prompt when the active model supports images. In the interactive composer, pasted image references are shown as attachment badges instead of editable filename/base64 text. Press Backspace at the beginning of the prompt to remove the most recent attachment. Transcripts show attachment badges and render the image inline when the terminal advertises a supported inline image protocol, such as iTerm2 or Kitty/WezTerm.
