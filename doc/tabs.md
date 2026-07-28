# Tabs

Use tabs when you want more than one Kward conversation open in the same interactive terminal session.

Normal tabs have their own session-backed conversation, transcript, composer state, and running agent turn. Plugins can also provide their own persistent tab types while Kward continues to supply the same composer and tab behavior. This makes tabs useful for splitting work without losing your place: one tab can investigate a bug, another can draft docs, and a third can wait on a long-running answer.

## Quick start

Open a new tab:

```text
/tab new
```

Switch to tab 1, 2, or another visible tab number:

```text
/tab 1
/tab 2
```

Rename the current tab:

```text
/tab name Docs
```

Close the current tab:

```text
/tab close
```

The tab bar appears at the bottom of the composer. The active tab is framed, and each tab label starts with its number.

## Worktree tabs

A normal session tab can be activated in a linked Git worktree after you have researched a task and decide that implementation should be isolated:

```text
/tab worktree
```

When enabled, Kward keeps the same tab and transcript but rebuilds its agent against a new worktree. The tab label includes the worktree branch. The worktree is created from `HEAD`, so Kward warns when the original workspace is dirty and leaves those existing changes in the original checkout; it does not copy them automatically. `/tab worktree activate` is an explicit alias for the same action.

Running `/tab worktree` again leaves an active worktree unchanged. To return the tab to its original workspace while keeping the linked worktree and branch, detach it explicitly:

```text
/tab worktree detach
```

Inspect, merge, or remove the binding explicitly:

```text
/tab worktree status
/tab worktree merge
/tab worktree remove
```

`/tab worktree merge` merges the active worktree's clean, committed branch directly into the branch currently checked out in its original workspace. Kward shows the source and target revisions and requires confirmation. Both worktrees must be clean. If Git reports conflicts, Kward leaves the original workspace in its normal merge state; resolve the conflicts there or cancel them with `/tab worktree merge abort`.

Removal refuses a dirty worktree and keeps its branch. A worktree that is missing or no longer points at the recorded branch is restored as unavailable rather than silently falling back to the original workspace.

Worktree tabs are available for normal session tabs, not plugin-owned tabs. Kward's file tools, `@`/`$` completion, `/files` browser, integrated editor, and model-requested shell workers use the active worktree root. Model operations retain strict workspace guardrails. The user-directed `/shell`, `!command`, `/capture`, and `/pty` features remain host-process operations and are not contained by the model command sandbox; use them only when that is intentional. Generic shell Git writes remain protected. When explicitly asked to commit, the agent can use the active tab's narrow `git_commit` tool; use the interactive `/git` flow when you want to review and commit changes yourself.

## Common workflow

A typical multi-tab flow looks like this:

1. Start Kward interactively in your project.
2. Use the main tab for the current implementation task.
3. Run `/tab new` to open a clean conversation.
4. Ask a separate question, such as:

   ```text
   Review the current API docs structure and suggest where a Tabs guide belongs.
   ```

5. Switch back with `/tab 1` while the other answer runs.
6. Return to the second tab with `/tab 2` when it is ready.

Tabs keep the conversations separate, so context from one tab does not automatically spill into another.

## Slash commands

| Command | Action |
| ------- | ------ |
| `/tab new` | Open a new tab with a fresh conversation |
| `/tab open <plugin-tab>` | Open a plugin-provided tab, such as a persistent companion chat. |
| `/tab 1` through `/tab 9` | Switch to a numbered tab |
| `/tab close` | Close the current tab |
| `/tab name <label>` | Rename the current tab |
| `/tab rename <label>` | Same as `/tab name` |
| `/tab worktree` | Create or activate the current session tab's linked Git worktree |
| `/tab worktree activate` | Explicitly create or activate the current session tab's linked Git worktree |
| `/tab worktree detach` | Return to the original workspace while keeping the linked worktree and branch |
| `/tab worktree status` | Show the current tab's worktree binding and Git status |
| `/tab worktree merge` | Merge the current worktree branch into the branch checked out in its original workspace |
| `/tab worktree merge abort` | Abort a conflicted worktree merge in the original workspace |
| `/tab worktree remove` | Remove a clean linked worktree and keep its branch |
| `/tab move left` | Move the current tab one slot left |
| `/tab move right` | Move the current tab one slot right |
| `/tab move <number>` | Move the current tab to a numbered position |

If you close the only remaining tab, Kward exits the interactive session. A running tab cannot be closed until it finishes or is cancelled.

## Keyboard shortcuts

Kward supports two tab shortcut families. You can choose one in `/settings` or with `composer.tab_keybindings` in `config.json`.

`Ctrl+Tab` and `Ctrl+Shift+Tab` switch tabs when your terminal sends those keys:

| Key | Action |
| --- | ------ |
| `Ctrl+Tab` | Next tab |
| `Ctrl+Shift+Tab` | Previous tab |

When `composer.tab_keybindings` is `ctrl`:

| Key | Action |
| --- | ------ |
| `Ctrl+T` | New tab |
| `Ctrl+W` | Close tab |
| `Ctrl+1` through `Ctrl+9` | Switch to a numbered tab, if your terminal reports modified number keys |

When `composer.tab_keybindings` is `alt`:

| Key | Action |
| --- | ------ |
| `Alt+T` | New tab |
| `Alt+Right` | Next tab |
| `Alt+Left` | Previous tab |
| `Alt+1` through `Alt+9` | Switch to a numbered tab |

`auto` is the default. On macOS it prefers the Ctrl family; elsewhere it prefers the Alt family, because many terminals reserve or swallow Ctrl-based tab shortcuts.

## Running work in another tab

A tab can keep running while you switch away. Kward marks tab labels by status:

- Yellow: running or queued.
- Green: waiting for your answer to an interactive question, or unread output is ready in a background tab.
- Red: failed or cancelled.

If you type into a busy tab, Kward queues normal prompts until the current turn finishes. Some running turns also support steering input, so short follow-up guidance may be delivered to the active run instead of waiting for the next turn.

Slash commands such as `/tab` still work while a tab is busy, so you can switch tabs, open a new tab, or move around without waiting.

## Persistence

Normal tabs are backed by Kward sessions. Plugins may also provide their own tab types; those tabs own their transcript and persistence independently of Kward sessions.

Kward stores the open tab list, labels, and active tab per workspace, then restores them the next time you start interactive Kward in that workspace. The tab layout is stored in Kward's config directory under `tabs/`. Session transcripts stay in the normal sessions directory. See [Sessions](session-management.md) for session naming, resuming, forking, exporting, and cleanup.

## Notes and limitations

- Tabs are available in the interactive TUI.
- Each tab has its own conversation context; use explicit file mentions or summaries when you want to carry information between tabs.
- A running tab cannot be closed until it is idle.
- Terminal support for modified keys varies. If shortcuts do not arrive, use the `/tab` slash commands or switch `composer.tab_keybindings` between `ctrl` and `alt`.
