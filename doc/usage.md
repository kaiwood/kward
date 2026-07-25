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

`/shell` opens `ekwsh`, a Kward-native command mode that keeps the tab bar and transcript visible. It preserves state such as the current directory, environment variables, and aliases between commands. Use `pty git log` or `/pty git log` when you intentionally want to hand the terminal to an interactive tool such as `less` or `vim`. See [Embedded shell](shell.md) for built-ins, completion, configuration, ANSI handling, PTY passthrough, and limitations.

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
kward rpc                      # start the RPC backend for trusted local UI clients
```

Use another workspace without changing directories:

```bash
kward --working-directory ~/code/project
kward --working-directory ~/code/project "Summarize this repository"
```

If your main config file is broken and prevents startup, use `--skip-config` to ignore it for one run:

```bash
kward --skip-config doctor
kward --skip-config edit ~/.kward/config.json
```

## Interactive slash commands

Slash commands run local actions in the current session. Most do not send a prompt to the model; exceptions like `/git` orchestrate local flows that may then trigger model work.

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
| `/settings` | configure models, accounts, memory, interface, tools, context, personalization, and logging. |
| `/status` | see session, model, and context status. |
| `/new` | start a fresh session in the current tab. |
| `/tab 2` | switch to tab 2. |
| `/tab move 1` | move the active tab to position 1. |
| `/tab move left` | move the active tab one position left. |
| `/tab move right` | move the active tab one position right. |
| `/tab close` | close the active tab. |
| `/tab new` | open a new tab. |
| `/tab name <label>` | rename the active tab label. |
| `/tab worktree` | toggle the active session tab into or out of a linked Git worktree. |
| `/tab worktree status` | inspect the active tab's worktree binding and changes. |
| `/tab worktree merge` | merge a clean worktree branch into the branch checked out in its original workspace. |
| `/tab worktree merge abort` | abort a conflicted worktree merge in the original workspace. |
| `/tab worktree remove` | remove a clean linked worktree while keeping its branch. |
| `/session` | open the saved sessions picker or continue a previous session by path. |
| `/resume` | alias for `/session`. |
| `/session name <name>` | name or clear the current session. |
| `/rename <name>` | rename the current session. |
| `/clone` | copy the current session into a new branch. |
| `/fork` | fork from an earlier prompt into a new session. |
| `/rewind` | revisit an earlier prompt and try a different direction. |
| `/tree` | inspect and navigate the full technical session tree. |
| `/copy last` | copy the latest assistant answer. |
| `/copy transcript` | copy the transcript as Markdown. |
| `/export notes.md` | write the transcript to a Markdown file. |
| `/compact [instructions]` | summarize older context so a long chat can continue. |
| `/memory ...` | manage opt-in memory. |
| `/skill <name>` | activate a configured skill explicitly for the current session. |
| `/stats [range]` | summarize enabled local telemetry. |
| `/hooks ...` | inspect, diagnose, trust, or untrust lifecycle hooks. |
| `/scratchpad [text|markdown|ruby]` | open an unsaved editor buffer. |
| `/redraw` | fix terminal drawing after resize or glitches. |
| `/reload` | reload installed plugins. |
| `/exit` | leave Kward. |
| `/quit` | alias for `/exit`. |

Prompt templates, configured skills, and plugins can add more slash commands. Their commands appear in the interactive slash-command picker alongside built-ins.

## Prompt history

The [Interactive composer](composer.md) guide covers multiline editing, slash and file completion, reasoning shortcuts, busy input, cancellation, attachments, and terminal compatibility.

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
/session
```

In the sessions picker, press `r` to rename the highlighted session, `c` to clone it, `f` to fork from an earlier prompt, or `d` twice to delete it. `/resume` remains available as an alias for `/session`.

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

If the active model supports images, Kward can attach image paths, Markdown image links, `file://` URLs, or image data URLs pasted into the composer. Supported formats are GIF, JPEG, PNG, and WebP, up to 20 MB per image. See [Interactive composer](composer.md#Attach_images) for attachment badges, removal, and terminal previews.

Use this for tasks such as:

```text
This screenshot shows the broken layout. Find the likely CSS issue.
```

## Pan mode

Pan mode starts a mobile-friendly LAN web UI:

```bash
kward --working-directory ~/code/project pan
```

Use it only on trusted networks. It exposes file, shell, web, and configured extension tools through a browser UI and requires credentials configured in `config.json`. Pan saves conversations to the normal workspace session store; its session drawer can create, resume, rename, and delete sessions. Session changes are disabled while turns are active or queued. See [Pan mode](pan.md) for setup, browser workflows, security, and limitations.

## RPC backend

`kward rpc` starts the JSON-RPC backend for trusted local UI clients and editor integrations. Terminal users can ignore it. Integration authors should read [RPC protocol](rpc.md).
