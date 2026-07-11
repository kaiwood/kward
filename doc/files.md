# Project files

Use `/files` when you want to browse the current workspace as a tree, open a file in Kward's integrated editor, or insert a file mention into the chat composer without typing the path by hand.

It is built for the moment when you know the file is somewhere in the project, but you do not want to leave the TUI to run `find`, `ls`, or your external editor. The browser opens as an overlay inside the composer and keeps you in the same conversation.

## Quick start

From an interactive Kward session, run:

```text
/files
```

Kward opens the project file browser. Use the arrow keys to move through the tree, then press `Enter` on a file to open it in the integrated editor.

When you quit the editor, Kward returns to the file browser at the same position so you can keep browsing nearby files.

## What appears in the browser

Inside a Git repository, `/files` uses Git's project view:

```bash
git ls-files --cached --others --exclude-standard
```

That means tracked files and normal untracked files appear, while ignored files stay out of the list.

Outside Git, Kward scans the workspace directory and skips common noisy directories such as `.git`, `.yardoc`, `_yardoc`, `node_modules`, `rdoc`, `tmp`, and `vendor/bundle`.

## Navigation

| Key | Action |
| --- | ------ |
| `↑` / `↓` | Move the selection |
| `Enter` | Open a file, or toggle a directory |
| `←` | Collapse the selected directory, or jump to its parent |
| `→` | Expand the selected directory |
| `Tab` | Start or stop search |
| `/` | Start search |
| `Backspace` | Delete the last search character |
| `Esc` | Leave search; press again to close the browser |
| `@` | Insert the selected file as an `@path` mention |

Directories use `▸` and `▾` markers to show collapsed and expanded state. Files are shown under their containing directory with indentation. File-type icons are off by default; users with a compatible Nerd Font can enable them under Interface in `/settings`. See [Configuration](configuration.md#project-browser-icons).

## Search files

Press `Tab` or `/` to search. While search is active, type part of a path and Kward filters the browser to matching files.

For example:

```text
/files
/agent
```

Use `↑` and `↓` to choose a result, then press `Enter` to open it. Press `Esc` to return to the tree view.

## Mention a file in chat

Press `@` on a selected file to insert it into the composer as an `@path` mention:

```text
@lib/kward/agent.rb
```

This is useful when you want Kward to talk about a specific file instead of opening it yourself. After inserting the mention, finish your prompt normally:

```text
@lib/kward/agent.rb Explain how tool execution works here.
```

## Open and edit files

Press `Enter` on a file to open it in the integrated editor. The editor uses your configured editor mode: Modern, Emacs, or Vibe.

A typical workflow:

1. Run `/files`.
2. Search for `README`, `agent`, or another path fragment.
3. Press `Enter` on the file you want.
4. Make the edit in the integrated editor.
5. Save and quit.
6. Continue browsing files, or press `Esc` to return to chat.

See [Integrated Editor](editor.md) for editor modes, save/quit keys, search, selection, and configuration.

## Remembered state

Kward remembers the expanded folders and selected path for each workspace. The next time you open `/files` in the same project, it restores the browser close to where you left it.

Search itself is temporary. Closing search returns to the normal tree, and closing the browser leaves your chat session intact.

## Notes and limitations

- `/files` is only available in the interactive prompt.
- It opens files inside the current workspace.
- It is a focused project browser, not a full file manager: it does not rename, move, copy, or delete files.
- Ignored Git files are intentionally hidden when Git can provide the file list.
