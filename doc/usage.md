# Usage

Kward has two main modes:

- **Interactive chat** for ongoing work in a project.
- **One-shot prompts** for quick questions, reviews, and summaries.

Run Kward from the workspace you want it to inspect:

```bash
cd ~/code/project
kward
```

When running from source, replace `kward` with `ruby lib/main.rb`.

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

## Shell commands

Useful shell commands:

```bash
kward                          # start interactive chat
kward "Explain this project"   # ask one question and exit
kward help                     # show commands and examples
kward doctor                   # check local setup
kward login                    # sign in or save credentials
kward auth status              # show credential status without secrets
kward sysprompt                # inspect assembled instructions
kward rpc                      # start the experimental RPC backend
```

Use another workspace without changing directories:

```bash
kward --working-directory ~/code/project
kward --working-directory ~/code/project "Summarize this repository"
```

## Interactive slash commands

Use slash commands for local actions that should not go to the model:

| Command | Use it when you want to... |
| --- | --- |
| `/login` | sign in or save provider credentials. |
| `/model` | choose the active model. |
| `/reasoning` | choose reasoning effort. |
| `/status` | see session, model, and context status. |
| `/new` | start a fresh session. |
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
| `/compact [focus]` | summarize older context so a long chat can continue. |
| `/memory ...` | manage opt-in memory. |
| `/redraw` | fix terminal drawing after resize or glitches. |
| `/exit` | leave Kward. |

Prompt templates and plugins can add more slash commands.

## Sessions

Interactive chats are saved under:

```text
~/.kward/sessions/
```

Sessions are scoped to the workspace. Use them when work spans more than one terminal sitting.

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

`/resume` remains available as an alias.

Use `/rewind` when you want to go back to an earlier prompt and try a different direction. Kward shows user prompts from the current session, lets you edit a prior prompt, and continues from that point as a branch. Use `/tree` when you need the full technical session tree, including branches, assistant entries, tool calls, and tool results.

Use `/compact` when a conversation gets long. Kward summarizes older context and keeps recent context active. After compaction, it may need to re-read files before editing them again.

## One-shot prompts

One-shot prompts are best for short tasks that do not need session history:

```bash
kward "What does this repository do?"
git diff | kward "Review this diff"
cat error.log | kward "Explain the likely cause"
```

Use `--` when your prompt starts with something that could be parsed as a command or option:

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

If the active model supports images, Kward can attach image paths, Markdown image links, `file://` URLs, or image data URLs pasted into the composer.

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
