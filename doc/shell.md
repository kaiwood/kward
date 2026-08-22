# Embedded shell

Kward lets you run your own shell commands without leaving the interactive TUI. Choose the workflow that matches what you are doing:

- **For one quick command, use `!command`.** It runs from the active workspace and returns you to the normal composer when it finishes.
- **For a longer stretch of shell work, use `/shell`.** It keeps its directory, environment, aliases, and history between commands.
- **For bounded output in the transcript view, use `/capture <command>`.** Inside `/shell`, use `capture <command>` for the same kind of readable output while keeping the shell's current state.

Ordinary `!command` input and external commands inside `/shell` receive an interactive PTY. Pagers, Vim, SSH, REPLs, password prompts, and other interactive tools therefore work without a `pty` prefix.

## Run a one-off command

Prefix a command with `!` in the normal composer:

```text
!git status --short
!bundle exec ruby -Itest test/test_cli.rb
!less README.md
```

The command runs from the active workspace root and begins in an inline PTY region above a frozen composer. Line-oriented output, single-line carriage-return progress, and synchronized-output update brackets scroll the transcript area naturally while keyboard input belongs to the child process. If the child emits alternate-screen, clear-screen, absolute cursor, or unknown terminal controls, Kward conservatively hides the composer and switches permanently to full-terminal passthrough for the rest of that command. Pagers and full-screen applications therefore retain the complete terminal without relying on a command-name allowlist.

When an inline command exits without reading input, safe output is mirrored into the transient transcript view so a repaint cannot hide it. Carriage-return and horizontal-cursor progress redraws are reduced to their final visible lines, while an unterminated synchronized-output update is closed before Kward redraws. If the child reads input, Kward retains only output captured before the first forwarded input byte; this prevents echoed passwords, OTPs, or other input from entering tab state. Shell output is never added to the AI conversation or sent to the model.

Shell output can leave transient text in the transcript area. **After the command finishes, press Ctrl+L to redraw the durable conversation and clear that transient `!command` output.** While an interactive command is still running, the composer remains frozen and keyboard input—including Ctrl+L and Kward's tab shortcuts—belongs to the child process.

Configured `ekwsh.yml` aliases also work after `!`:

```yaml
aliases:
  glog: "git log --decorate --stat --graph"
```

```text
!glog
```

An alias that resolves to `kward edit <filename>` opens Kward's integrated editor in the current session instead of starting a nested Kward process:

```yaml
aliases:
  vibe: "kward edit"
```

```text
!vibe filename.txt
```

Press Tab after `!` to complete configured aliases, executables from `PATH`, and paths from the active workspace:

```text
!git sta<Tab>
!cat lib/kwa<Tab>
```

The completion overlay lists matching commands and paths. Press Tab repeatedly to cycle through the listed candidates.

## Work in shell mode

Enter the embedded shell when you expect to run several commands:

```text
/shell
```

The prompt changes to show the shell's current directory:

```text
Shell ~/code/project $
```

The directory and exported environment persist between commands:

```sh
cd test
pwd
export RAILS_ENV=test
bundle exec ruby -Itest test_example.rb
unset RAILS_ENV
```

Simple assignment-only commands persist too:

```sh
FOO=bar
printf '%s\n' "$FOO"
```

Leave shell mode with `exit`, `logout`, or Ctrl+D on an empty prompt.

`cd` changes only the embedded shell's directory. It does not change Kward's workspace root or the directory used by the model's other tools.

## Interactive and captured commands

External commands inside `/shell` are interactive by default:

```sh
git log
vim README.md
ruby
ssh example.com
```

Kward gives each command the terminal, forwards keyboard input, and restores the shell prompt when the command exits. It prints the submitted command but no PTY start message or exit-status summary. The line-oriented Git commands `git fetch`, `git ls-remote`, `git push`, `git remote`, and `git status` keep the shell prompt visible as a frozen display. Safe, line-oriented output from commands that did not read keyboard input is kept in the transient transcript view; full-screen and genuinely interactive output stays terminal-owned.

Use `capture` inside `/shell` when you want ordinary, readable output in Kward's transcript area instead of direct terminal control:

```sh
capture git status --short
capture bundle exec ruby -Itest test/test_ekwsh.rb
```

An `ekwsh` `capture` command:

- does not receive keyboard input,
- uses the timeout and output-size limit from `ekwsh.yml`,
- preserves safe color and styling,
- strips controls that could corrupt Kward's TUI,
- can be cancelled with Ctrl+C.

From the normal composer, `/capture` provides a bounded, noninteractive one-shot command using the active workspace root:

```text
/capture git status --short
```

It captures stdout and stderr in the transcript view, but does not inherit `/shell` state or its configured runtime limits.

Interactive commands are not automatically timed out or output-limited. Ctrl+C is forwarded to the child.

The older `/pty <command>` slash command and `pty <command>` shell built-in remain available for compatibility, but ordinary interactive commands no longer need them.

## Shell state, history, and tabs

Each Kward tab owns its `/shell` state. Switching away and back restores that tab's:

- current shell directory,
- exported environment,
- runtime aliases,
- shell prompt and transcript view.

Shell commands use a separate, workspace-scoped history rather than the normal chat-prompt history. Configure its size with `history_limit` in `ekwsh.yml`.

Kward's tab shortcuts work at the shell prompt and while a captured command is running. During an interactive command, the child owns every key; exit or interrupt it before switching Kward tabs.

## Completion

Press Tab in `/shell` to complete:

- built-in names,
- configured and runtime aliases,
- executables from `PATH`,
- files and directories from the shell's current directory.

Examples:

```sh
pw<Tab>          # pwd
ll<Tab>          # configured alias
cat lib/kw<Tab>  # path
cd doc<Tab>      # directories only for cd
```

Paths with spaces are escaped:

```sh
cat my<Tab>
# => cat my\ file.txt
```

Quoted paths stay quoted:

```sh
cat "my<Tab>
# => cat "my file.txt
```

When several candidates match, repeated Tab presses cycle through them and wrap back to the first. Candidate lists stay in the composer instead of being printed in the transcript. The executable cache refreshes when `PATH` changes through assignment, `export`, or `unset`.

## Built-ins

`ekwsh` handles a small set of commands itself so their state can persist:

| Built-in | What it does |
| --- | --- |
| `cd [dir]` | Change the shell directory. Supports `cd`, `cd -`, and relative paths. |
| `pwd` | Print the shell directory. |
| `export KEY[=value]` | Set an environment variable. `export` and `export -p` list variables. |
| `unset KEY` | Remove an environment variable. |
| `alias [name]` | List, inspect, or create aliases. |
| `unalias name` / `unalias -a` | Remove aliases. |
| `capture <command>` | Run with bounded, sanitized transcript output. |
| `pty <command>` | Compatibility spelling for interactive terminal handoff. |
| `clear` | Clear the visible transcript. |
| `exit` / `logout` | Leave shell mode. |

Built-ins take precedence over aliases and executables.

## Configure ekwsh

Global shell configuration lives at:

```text
~/.kward/ekwsh.yml
```

When `KWARD_CONFIG_PATH` selects another main config file, Kward reads `ekwsh.yml` from the same directory.

A practical configuration might look like this:

```yaml
shell: /bin/sh
timeout_seconds: 300
max_output_bytes: 1048576
history_limit: 1000

env:
  FORCE_COLOR: "1"
  BUNDLE_WITHOUT: "production"
  RAILS_ENV: "test"

aliases:
  ll: "ls -la"
  gs: "git status --short"
  gd: "git diff --color=always"
  glog: "git log --decorate --stat --graph"
  be: "bundle exec"
  t: "bundle exec ruby -Itest"
```

### Settings

| Setting | Default | What it does |
| --- | --- | --- |
| `shell` | `/bin/sh` | POSIX-compatible shell used with `-c`. It must be an absolute executable path. |
| `timeout_seconds` | `300` | Maximum runtime for one captured command. |
| `max_output_bytes` | `1048576` | Maximum output retained for one captured command. |
| `history_limit` | `1000` | Maximum shell-history entries per workspace. |

Invalid or relative `shell` paths fall back to `/bin/sh`. These timeout and output limits apply only to `capture` inside `/shell`, not interactive commands or the separate `/capture` slash command.

### Environment

Configured `env` values are applied when `/shell` starts. Keys must be valid environment-variable names; nil values and invalid keys are ignored, and other values are converted to strings.

Kward also supplies conservative terminal defaults:

```sh
CLICOLOR=1
COLORTERM=truecolor
TERM=xterm-256color  # only when TERM is missing or dumb
```

It does not force color. Set `FORCE_COLOR`, `CLICOLOR_FORCE`, or a command-specific option such as `--color=always` when needed.

When rbenv is available, Kward adds its shims and bin directories to `PATH` and supplies `RBENV_ROOT` if it was missing. This lets `ruby`, `bundle`, and `./exe/kward` use the selected Ruby without sourcing shell startup files.

### Aliases

Aliases replace the first command word once and append any remaining arguments:

```yaml
aliases:
  ll: "ls -la"
  t: "bundle exec ruby -Itest"
```

```sh
ll lib
# runs: ls -la lib

t test/test_ekwsh.rb
# runs: bundle exec ruby -Itest test/test_ekwsh.rb
```

Configured aliases work inside `/shell` and after `!`. Aliases created with the `alias` built-in belong only to the current `/shell` session and are not shared with one-shot `!command` input.

For compatibility with older configs, Kward removes a leading `pty` or `capture` mode marker when a configured alias is invoked through `!`, because `!command` is always interactive.

Aliases are intentionally simple: they do not expand recursively and are not shell functions. Use `alias` to list them, `alias name=value` to create a runtime alias, and `unalias` to remove one.

## Terminal output and safety

Interactive commands write directly to your terminal so full-screen tools can work. When a command does not read keyboard input and emits only line-oriented text plus safe color sequences, Kward mirrors that output into the transient transcript view after the command exits. Other interactive output is not sanitized and may contain terminal control sequences, so run only commands you trust with terminal access.

Commands run with `capture` inside `/shell` preserve safe ANSI color and style sequences while removing cursor movement, clear-screen controls, title changes, alternate-screen controls, and similar sequences that could damage the TUI transcript.

## Limitations

`ekwsh` manages shell-like state, but it is not a persistent login shell or terminal emulator:

- each external command runs separately through the configured shell,
- there is no job control; a stopped child is terminated rather than leaving the terminal stranded,
- shell functions do not persist and shell startup files are not sourced,
- there is no login-shell readline integration,
- full-screen terminal state is not retained after an interactive command exits,
- safe line-oriented output may remain in the transient TUI transcript, but full-screen terminal state is not retained and no shell output becomes part of the AI conversation.
