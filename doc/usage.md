# Usage

Kward has two main modes:

- **Interactive chat** for ongoing work in a project.
- **One-shot prompts** for quick questions, reviews, and summaries.

Run Kward from the workspace you want it to inspect:

```bash
cd ~/code/project
kward
```

When running from source, replace `kward` with `ruby lib/main.rb`. See [Getting started](getting-started.md) for install and sign-in.

## Common workflows

### Understand a new project

```text
Explain the project structure and point out the main entry points.
```

Useful follow-ups:

```text
Where is configuration loaded?
Which files would I read first to understand authentication?
Summarize the test strategy.
```

### Review changes before committing

```bash
git diff | kward "Review this diff for bugs, missing tests, and confusing naming"
```

For larger reviews, use interactive mode so Kward can inspect related files:

```text
Review the current git diff. If something looks risky, inspect the relevant files before recommending changes.
```

To review and commit changes interactively, use `/git`:

```text
/git
```

It opens a staging overlay where you can stage or unstage files, preview diffs, and write a commit message without leaving Kward.

### Make a small code change

```text
Add a --json option to the status command. Keep the text output unchanged and add focused tests.
```

Kward must read an existing file in the current conversation before editing it. This guardrail helps prevent accidental overwrites.

### Run local checks

Inside interactive mode, ask Kward to run a command:

```text
Run the focused test for the CLI status command.
```

Or run a shell command yourself from the composer by prefixing it with `!`:

```text
!git status --short
```

For several commands, enter the embedded Kward shell:

```text
/shell
```

`/shell` opens `ekwsh`, a Kward-native command mode. Kward keeps the tab bar, composer editing, and transcript rendering while each command runs through your configured shell. Built-ins such as `cd`, `pwd`, `export`, `unset`, `alias`, `clear`, `pty`, and `exit` maintain shell-mode state between commands. Plain Tab completes built-in command names, configured aliases, executables from `$PATH`, and file paths from the shell's current directory; `cd` completion suggests directories only. `ekwsh` preserves safe ANSI SGR color/style output while stripping terminal-control sequences that could corrupt the TUI, and sets conservative color-friendly environment defaults such as `CLICOLOR=1`, `COLORTERM=truecolor`, and `TERM=xterm-256color` when needed. Use `pty git log` or `/pty git log` when you intentionally want to hand the terminal to an interactive tool such as `less` or `vim`. You can set global shell env vars and aliases in `~/.kward/ekwsh.yml`; see [Configuration](configuration.md).

## Shell commands

Useful shell commands:

```bash
kward                          # start interactive chat
kward "Explain this project"   # ask one question and exit
kward help                     # show commands and examples
kward version                  # show the installed version
kward doctor                   # check local setup
kward login                    # sign in or save credentials
kward auth status              # show credential status without secrets
kward sysprompt                # inspect assembled instructions
kward stats tokens             # export local token telemetry as CSV
kward rpc                      # start the experimental RPC backend
```

Use another workspace without changing directories:

```bash
kward --working-directory ~/code/project
kward --working-directory ~/code/project "Summarize this repository"
```

## Interactive slash commands

Slash commands run local actions in the current session. Most do not send a prompt to the model; exceptions like `/git` and `/workers` orchestrate local flows that may then trigger model work.

| Command | Use it when you want to... |
| --- | --- |
| `/login` | sign in or save provider credentials. |
| `/model` | choose the active model. |
| `/reasoning` | choose reasoning effort. |
| `/git` | review uncommitted changes, stage files, and commit. |
| `/diff` | open the file changes recorded in the current session. |
| `/files` | browse project files in a nested tree and open them in the editor. |
| `/shell` | run workspace commands in the embedded Kward shell. |
| `/pty <command>` | hand the terminal to an interactive command such as `git log`/`less` or `vim`. |
| `/settings` | configure prompt overlays. |
| `/status` | see session, model, and context status. |
| `/new` | start a fresh session in the current tab. |
| `/tab 2` | switch to tab 2. |
| `/tab move 1` | move the active tab to position 1. |
| `/tab move left` | move the active tab one position left. |
| `/tab move right` | move the active tab one position right. |
| `/tab close` | close the active tab. |
| `/tab new` | open a new tab. |
| `/tab name <label>` | rename the active tab label. |
| `/sessions` | open the saved sessions picker or continue a previous session by path. |
| `/resume` | alias for `/sessions`. |
| `/name <name>` | name or clear the current session. |
| `/rename <name>` | rename the current session. |
| `/clone` | copy the current session into a new branch. |
| `/rewind` | revisit an earlier prompt and try a different direction. |
| `/tree` | inspect and navigate the full technical session tree. |
| `/copy last` | copy the latest assistant answer. |
| `/copy transcript` | copy the transcript as Markdown. |
| `/export notes.md` | write the transcript to a Markdown file. |
| `/compact [instructions]` | summarize older context so a long chat can continue. |
| `/memory ...` | manage opt-in memory. |
| `/redraw` | fix terminal drawing after resize or glitches. |
| `/reload` | reload installed plugins. |
| `/workers` | open the experimental worker pipeline (`new`, `do <task>`, or `list`). |
| `/queue` | manage the experimental tab-backed worker queue (`add`, `list`, `open <id>`, `run`, `suspend <id>`, or `resume <id>`). |
| `/exit` | leave Kward. |

Prompt templates and plugins can add more slash commands.

## Prompt history

In interactive mode, Kward keeps prompt history per workspace under `~/.kward/history/`. Press Up/Down to recall previous prompts across restarts.

Press `Ctrl-R` to search history. Type a fuzzy query in the composer, use Up/Down to choose a result from the overlay, then press Enter to place it back in the composer for editing or resubmission. Press Esc or Ctrl-C to cancel the search and restore the draft.

`$path` editor-open commands are also saved after a file opens successfully, using the resolved workspace-relative path.

## Sessions

Interactive chats are saved as workspace-scoped sessions under:

```text
~/.kward/sessions/
```

Use sessions when work spans more than one terminal sitting, or when you want to branch a conversation and try another direction.

Typical flow:

```text
/rename oauth cleanup
# work with Kward
/export oauth-notes.md
/exit
```

Later:

```text
/sessions
```

In the sessions picker, press `r` to rename the highlighted session, `c` to clone it, `f` to fork from an earlier prompt, or `d` twice to delete it. `/resume` remains available as an alias for `/sessions`.

For the full guide to context management, cloning, forking, rewinding, `/tree`, compaction, and exports, read [Sessions](session-management.md).

## One-shot prompts

One-shot prompts are best for short tasks that do not need session history:

```bash
kward "What does this repository do?"
cat error.log | kward
```

When stdin and a prompt are both present, Kward runs in filter mode: stdin is the input, the prompt is the instruction, and stdout contains only the transformed result. You can also force this with `--filter` or `--mode filter`.

```bash
git diff | kward "Review this diff"
echo "Hello" | kward --filter "Translate to German"
kward --mode filter "Indent this JSON" < unindented.json
```

Use `--mode chat`, `--mode oneshot`, or `--mode filter` to override automatic mode detection. Use `--` when your prompt starts with something that could be parsed as a command or option:

```bash
kward -- explain --working-directory
```

One-shot prompts do not use Kward memory.

## Workspace tools

During a turn, Kward can inspect and change the workspace with tools for:

- listing and reading files,
- creating and editing files,
- running shell commands,
- searching the web,
- fetching specific URLs,
- inspecting public source repositories,
- asking structured clarification questions.

Important guardrails:

- Existing files must be read before Kward can edit or overwrite them.
- File reads and edits are bounded to avoid loading very large files by accident.
- Shell commands run from the workspace and should be treated like commands you run yourself.

## Images

If the active model supports images, Kward can attach image paths, Markdown image links, `file://` URLs, or image data URLs pasted into the composer. Supported formats are GIF, JPEG, PNG, and WebP, up to 20 MB per image.

Use this for tasks such as:

```text
This screenshot shows the broken layout. Find the likely CSS issue.
```

## Pan mode

Pan mode starts a simple LAN web UI:

```bash
kward --working-directory ~/code/project pan
```

Use it only on trusted networks. It exposes the same file, shell, and web tools through a browser UI and requires credentials configured in `config.json`. See [Configuration](configuration.md).

## RPC backend

`kward rpc` starts the experimental JSON-RPC backend for UI clients and editor integrations. Terminal users can ignore it. Integration authors should read [RPC protocol](rpc.md).
