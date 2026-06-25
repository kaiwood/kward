# Git

Kward has a small interactive Git workflow built into the terminal UI. It lets you review the current working tree, inspect per-file diffs, stage or unstage files, write a commit message, and create a commit without leaving the chat.

Use it when you have just finished a change with Kward and want one last pass before committing. It is intentionally focused: it is not a full Git client, just the common review-and-commit loop.

## Quick start

From an interactive Kward session inside a Git repository, run:

```text
/git
```

Kward opens a Git overlay showing the same short status style you would see from:

```bash
git status --short --untracked-files=normal
```

Example:

```text
 M lib/kward/cli.rb
A  doc/git.md
?? tmp/example.txt
```

Use the overlay to review and shape the commit:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Move between changed files. |
| `Enter` | Open the selected file in the diff viewer. |
| `s` | Stage or unstage the selected file. |
| `Tab` | Switch to commit-message entry. |
| `Esc` | Cancel and return to chat. |

When you press `Tab`, the prompt changes from `Git>` to `Commit>`. Type the commit message and press `Enter` to commit. Press `Tab` again to return to the file list without losing the draft message.

## Review changes with the diff viewer

Highlight a file in the `/git` overlay and press `Enter`.

Kward opens a read-only diff viewer in the composer area. It shows classic Git diff output with added and removed lines colorized when terminal color is enabled.

Useful keys in the diff viewer:

| Key | Action |
| --- | --- |
| `↑` / `↓` | Move through the diff one line at a time. |
| `Page Up` / `Page Down` | Scroll by a page. |
| `Home` / `End` | Move within the current line. |
| `/` or `Ctrl+F` | Search within the diff. |
| `Enter` | Confirm the current search. |
| `Esc` | Cancel search, or close the diff viewer. |
| `Ctrl+Q` | Close the diff viewer. |

After you close the viewer, Kward returns to the Git overlay with the file list refreshed.

The diff viewer is read-only. It is meant for checking what changed, not editing. If you spot something you want to fix, close the viewer, return to chat, and ask Kward to make the change or open the file with the built-in editor using `$path/to/file`.

## Example workflow

A typical end-to-end flow looks like this:

```text
/git
```

1. Use `↑` and `↓` to scan the changed files.
2. Press `Enter` on a file that looks risky.
3. Search the diff with `/` if you need to find a symbol or error message.
4. Press `Esc` to close the diff viewer.
5. Press `s` on files you want in this commit.
6. Press `Tab` to write the commit message.
7. Press `Enter` to commit.

If no files are staged when you submit the commit message, Kward stages all current workspace changes before committing. If at least one file is already staged, Kward commits only the staged changes.

That means you can use `/git` in two ways:

- **Simple commit:** do not stage anything manually; write a message and Kward commits all current changes.
- **Selective commit:** stage specific files with `s`; Kward commits only what is staged.

## How staged changes work

The `s` key toggles the selected file:

- unstaged files are staged with `git add -- <path>`
- staged files are unstaged with `git restore --staged -- <path>`

The status list refreshes after each toggle, so you can see what will be included before committing.

For untracked files, the diff viewer shows the file as a new file with every line added. That makes it possible to review new files before staging them.

## Git branch indicator

In the interactive composer status line, Kward also shows the current Git branch or short commit SHA when the workspace is inside a repository. The indicator turns yellow when the working tree has uncommitted changes.

This is just a lightweight status hint. Use `/git` when you want to review or commit the changes.

## Notes and limitations

- `/git` is available in the interactive terminal UI, not in one-shot prompts.
- The command must run inside a Git repository.
- The diff viewer compares tracked files against `HEAD` with `git diff HEAD -- <path>`.
- The commit command uses `git commit -m <message>`.
- Kward does not push, pull, merge, rebase, amend, or manage branches from this overlay.
- Commit success still depends on your local Git configuration, hooks, and repository state.

For AI-assisted review without committing, you can still pipe a diff into a one-shot prompt:

```bash
git diff | kward "Review this diff"
```
