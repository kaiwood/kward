# Interactive composer

The composer is the input area at the bottom of Kward's interactive terminal UI. It is more than a single-line prompt: it supports multiline editing, command and file completion, persistent history, image attachments, reasoning selection, background tabs, queued follow-ups, and in-flight steering.

This guide is a practical keyboard reference for working quickly without leaving the conversation.

## Write and submit a prompt

Type a prompt and press Return to submit it:

```text
Find where authentication errors are handled and explain the flow.
```

Use Shift+Return to insert a newline without submitting:

```text
Review the current diff.
Focus on:
- correctness
- missing tests
- confusing naming
```

Modified Enter support depends on what your terminal sends. If Shift+Return is swallowed or arrives as an ordinary Return, paste multiline text with bracketed paste, or compose it in another editor before pasting.

The composer supports familiar line-editing keys:

| Key | Action |
| --- | --- |
| `Left` / `Right` | Move by character |
| `Home` / `Ctrl+A` | Move to the start of the current line |
| `End` / `Ctrl+E` | Move to the end of the current line |
| `Ctrl+B` / `Ctrl+F` | Move left or right |
| `Alt+B` / `Alt+F` | Move by word |
| `Backspace` / `Delete` | Delete before or at the cursor |
| `Ctrl+W` | Delete the word before the cursor |
| `Alt+D` | Delete the word after the cursor |
| `Ctrl+U` / `Ctrl+K` | Kill from the cursor to the start or end of the line |
| `Ctrl+Y` | Yank the most recently killed composer text |
| `Ctrl+L` | Redraw the terminal UI |
| `Ctrl+D` | Delete at the cursor, or exit when the composer is empty |

These are composer bindings. The integrated editor, shell, Git view, file browser, and plugin interfaces have their own keymaps.

## Find slash commands

Type `/` at the beginning of the composer to open the slash-command picker:

```text
/ses
```

Use Up/Down to select a match. Press Tab to complete it, then add arguments if needed:

```text
/session name OAuth cleanup
```

Press Esc to dismiss the picker without deleting your draft. Return submits the command.

The picker includes:

- Kward's built-in commands,
- configured prompt templates,
- configured skills as `/skill:<name>`,
- plugin slash commands,
- plugin interactive commands.

See [Usage](usage.md#Interactive_slash_commands) for the built-in command reference and [Extensibility](extensibility.md) for adding commands.

## Mention a file with `@`

Type `@` followed by part of a workspace path anywhere in a prompt:

```text
@agent
```

Kward shows fuzzy project-file matches. Use Up/Down to select one and Tab to insert the path:

```text
@lib/kward/agent.rb Explain how tool execution works here.
```

An `@path` is a textual pointer for the agent. It does not automatically place the whole file into model context; Kward can inspect the file with its tools when the task requires it. This keeps large files from being attached blindly.

Press Esc to dismiss file completion. You can also insert a mention from the `/files` browser with `@`. See [Project files](files.md).

## Open a file with `$`

Start the composer with `$` to open a workspace file in the integrated editor:

```text
$lib/kward/agent.rb
```

The `$` token must begin at the first character of the composer. Use Up/Down to choose a match, then press Return or Tab to open it. If you type a path that does not exist and press Return, Kward can ask whether to create it.

A successful `$path` open is saved in prompt history using the resolved workspace-relative path. It opens the editor instead of sending a model prompt.

See [Integrated Editor](editor.md) for editing modes, save and quit keys, scratchpads, and conflict handling.

## Reuse prompt history

Kward stores prompt history per workspace under `~/.kward/history/`.

- Press Up/Down when no completion picker is visible to move through earlier prompts.
- Press `Ctrl+R` to start fuzzy history search.
- Type a query, then use Up/Down to choose a match.
- Press Return to place the selected result back into the composer for editing or submission.
- Press Esc or `Ctrl+C` to cancel search and restore the draft you had before searching.

History survives restarts. It contains submitted prompt text and successful `$path` editor-open commands, so protect it like other local Kward data. See [Security and trust](security.md#Local_data_and_permissions).

## Change reasoning effort

When no slash or file picker is open, Tab cycles forward through reasoning efforts supported by the current model. Shift+Tab cycles backward. The selection wraps and is persisted for later turns.

The composer status line shows the current provider, model, and reasoning effort. Use `/reasoning` or `/model` when you prefer the explicit picker.

Tab is context-sensitive:

- in slash or `@path` completion, it accepts the selected match,
- in `$path` completion, it opens the selected file,
- otherwise, it changes reasoning effort,
- in other modal interfaces, it follows that interface's own controls.

## Work with tabs

`Ctrl+Tab` and `Ctrl+Shift+Tab` switch conversations when your terminal reports those keys. Additional shortcuts depend on `composer.tab_keybindings`:

- `ctrl`: `Ctrl+T` creates a tab, `Ctrl+W` closes one, and reported `Ctrl+1` through `Ctrl+9` select numbered tabs.
- `alt`: `Alt+T` creates a tab, `Alt+Left`/`Alt+Right` move between tabs, and `Alt+1` through `Alt+9` select numbered tabs.
- `auto`: prefers the Ctrl family on macOS and the Alt family elsewhere.

Use `/settings` → Interface → Tab keybindings to change the family. If your terminal intercepts a shortcut, `/tab` commands always provide the same operations.

See [Tabs](tabs.md) for background work, status colors, persistence, naming, and moving tabs.

## Type while Kward is busy

The composer stays available during a model turn or many long local actions.

For a normal model turn:

- If the current provider supports native in-flight steering, a non-empty prompt is sent as guidance to the running turn. Kward marks it as steered until the model applies it.
- If steering is unavailable or fails, the prompt is queued and starts after the active turn.
- Kward displays queued and steered counts in the busy composer.

Use steering for short corrections that should affect work already in progress:

```text
Do not change the public API. Keep the fix internal.
```

Use a separate tab when you want an independent task rather than a correction to the current one.

Most slash commands typed into a busy composer are intentionally ignored because delayed local state changes would be surprising. `/exit`, `/quit`, and `/new` are queued as control actions. `/tab` commands run immediately while work runs, so you can name, switch, open, or move tabs; closing the running tab remains unavailable.

During local operations that do not support steering, submitted text is queued for later processing.

## Cancel running work

Press `Ctrl+C` while the busy composer is active to request cancellation of the current operation. Kward stops rendering further work and cooperatively cancels model and tool activity where possible.

Cancellation is best effort. A network request, shell command, or side effect already in progress may finish before the underlying API can stop. Always inspect the workspace after cancelling a mutating task.

When Kward is idle, `Ctrl+C` does not exit the interactive session. Use `/exit`, `/quit`, or `Ctrl+D` on an empty composer.

The busy composer shows a cancellation hint by default. Hide only the hint—not cancellation itself—with `composer.busy_help: false` or the Interface settings menu.

## Attach images

Paste supported image references into the composer. Kward recognizes:

- image paths,
- Markdown image links,
- `file://` URLs,
- base64 image data URLs.

Supported formats are GIF, JPEG, PNG, and WebP, up to 20 MB per image. Pasted references become badges above the draft, and their source text is removed from the visible prompt. Duplicate pasted references are ignored. References typed normally are resolved when the prompt is submitted.

Example:

```text
./tmp/broken-layout.png Find the likely CSS problem shown in this screenshot.
```

If the cursor is at the start of an otherwise empty draft, Backspace removes the most recently added pending attachment. Submitting the draft clears its pending attachments.

The active model must support image input. iTerm2 and Kitty-compatible terminals can render submitted images inline; other terminals still show attachment badges and send the image to the model without an inline preview.

## Understand composer status

The composer area can include:

- the current Git branch or short commit, colored yellow when dirty,
- additions and deletions recorded in the current session,
- approximate context-window usage,
- provider, model, and reasoning effort,
- a tab bar plus queued or steered input counts,
- an optional plugin footer.

Context usage is an estimate, not provider billing. Use `/status` for more session and compaction detail.

## Recover from terminal issues

Terminal support for Shift+Return, Ctrl+Tab, modified number keys, OSC clipboard access, and inline images varies.

If rendering becomes corrupted after resize or after an external program writes terminal controls:

```text
/redraw
```

You can also press `Ctrl+L`. If a shortcut never reaches Kward, prefer its slash-command equivalent or change `composer.tab_keybindings` in `/settings`.

For full-screen interactive programs such as Vim or `less`, use `/pty <command>` or `pty <command>` inside `/shell` so the program temporarily owns the terminal instead of fighting the composer.
