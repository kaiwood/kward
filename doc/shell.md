# Embedded shell

Use `/shell` when you want to run a sequence of local commands without leaving Kward's interactive TUI.

`/shell` opens **ekwsh**, the embedded Kward shell. It is not a full terminal emulator. Kward manages persistent shell state and hands the terminal to each external command one at a time.

This makes it good for:

- checking Git state,
- running focused tests,
- inspecting files with command-line tools,
- using project aliases,
- keeping command output visible beside the current Kward session.

External commands receive an interactive PTY by default, so tools such as `less`, Vim, SSH, and REPLs work without a prefix. Use `capture <command>` when you want bounded, transcript-friendly output instead.

## Start shell mode

Inside interactive Kward:

```text
/shell
```

The composer prompt changes to show the shell's current directory:

```text
Shell ~/code/project $
```

Type commands as you would in a normal shell:

```sh
git status --short
bundle exec ruby -Itest test/test_ekwsh.rb
cd lib/kward
pwd
```

Leave shell mode with:

```sh
exit
```

or press Ctrl+D on an empty shell prompt.

## How commands run

`ekwsh` is POSIX-oriented and runs each command through `/bin/sh` using the shell's `-c` mode by default. You can configure another POSIX-compatible shell in `ekwsh.yml`. The shell is intentionally not started as a login shell so Kward-managed environment values, such as configured PATH entries, are not overwritten by login startup files.

The current directory and exported environment are tracked by Kward between commands, so this works as expected:

```sh
cd test
pwd
export FOO=bar
printf '%s\n' "$FOO"
unset FOO
```

`cd` changes only the embedded shell's current directory. It does not change Kward's workspace root or the process directory used by the rest of Kward.

Interactive command output streams directly to the terminal and is not added to the AI conversation history or durable Kward transcript. Kward records a short command and exit-status summary. `capture <command>` streams sanitized output into the transcript instead. Simple assignment-only commands such as `FOO=bar` persist into the embedded shell environment for later commands.

Shell commands are persisted in a separate workspace-scoped shell history. They do not share the normal Kward prompt history used for chat prompts. The shell history limit is controlled by `history_limit` in `ekwsh.yml`.

## Built-ins

`ekwsh` handles a small set of built-ins itself:

| Built-in | What it does |
| --- | --- |
| `cd [dir]` | Change the embedded shell directory. Supports `cd`, `cd -`, and normal relative paths. |
| `pwd` | Print the embedded shell directory. |
| `export KEY[=value]` | Set or mark an environment variable for later commands. `export` and `export -p` list variables. |
| `unset KEY` | Remove an environment variable from later commands. |
| `alias [name]` | List configured aliases, show specific configured aliases, or set `alias name=value`. |
| `unalias name` / `unalias -a` | Remove configured aliases. |
| `capture <command>` | Run with bounded, sanitized transcript capture instead of interactive terminal handoff. |
| `pty <command>` | Compatibility spelling for explicit interactive terminal handoff. |
| `clear` | Clear Kward's visible transcript. |
| `exit` / `logout` | Leave shell mode. |

Built-ins take precedence over aliases and executables.

## Tabs

Shell mode is tracked per Kward tab.

If you enter `/shell` in one tab, switch to another tab, and later switch back, that tab is still in shell mode. Its shell state and transcript snapshot are restored until you leave shell mode in that tab.

This means each tab can have its own:

- shell current directory,
- exported environment,
- visible shell transcript,
- command prompt state.

Kward's normal tab-switching shortcuts work while the shell prompt or a captured command is active. During an interactive external command, the child owns all keyboard input, including keys that normally switch Kward tabs. Exit or interrupt the child before switching tabs.

## Tab completion

Plain Tab completes shell input while in `ekwsh`.

Completion includes:

- built-in command names,
- configured aliases,
- executable names from `$PATH`,
- file paths from the shell's current directory.

Examples:

```sh
pw<Tab>          # pwd
ll<Tab>          # configured alias, if present
cat lib/kw<Tab>  # path completion
cd doc<Tab>      # directory-only completion for cd
```

Directory completions get a trailing slash. File and command completions get a trailing space when there is a single match.

Paths with spaces are shell-escaped:

```sh
cat my<Tab>
# => cat my\ file.txt
```

Quoted path tokens are completed in the same quoting style:

```sh
cat "my<Tab>
# => cat "my file.txt
```

If there are multiple candidates, repeated Tab presses cycle through them in order and wrap back to the first candidate. Completion candidates stay in the composer and are not printed in the transcript. Command-name completion caches `$PATH` executables and refreshes when `PATH` changes through shell assignment, `export`, or `unset`.

## Colors and ANSI output

Captured `ekwsh` output preserves safe ANSI SGR color/style sequences, such as:

- colors,
- bold,
- dim,
- italic,
- underline,
- 256-color and truecolor SGR sequences.

Captured output strips terminal-control sequences that could corrupt Kward's TUI, such as cursor movement, clear-screen controls, OSC title changes, and alternate-screen controls. Interactive commands write directly to the terminal without this sanitization so full-screen tools can work correctly; run only commands you trust with terminal access.

When rbenv is available, `ekwsh` also prepends the rbenv shims and bin directories to PATH and sets `RBENV_ROOT` when it was missing. This lets commands such as `ruby`, `bundle`, and `./exe/kward` use the same Ruby selected by rbenv without requiring `rbenv init` support in `ekwsh`.

By default, `ekwsh` sets conservative color-friendly environment values:

```sh
CLICOLOR=1
COLORTERM=truecolor
TERM=xterm-256color  # only when TERM is missing or dumb
```

It does **not** force color by default. If a tool does not emit color because stdout is not a TTY, use a command-specific flag or configure forced color yourself:

```sh
git diff --color=always
grep --color=always TODO lib/**/*.rb
```

## Global ekwsh config

You can configure environment variables and aliases in:

```text
~/.kward/ekwsh.yml
```

If `KWARD_CONFIG_PATH` points to another config file, `ekwsh.yml` is read from that file's directory instead.

Example:

```yaml
shell: /bin/sh
# timeout_seconds: 300
# max_output_bytes: 1048576
# history_limit: 1000

env:
  FORCE_COLOR: "1"
  CLICOLOR_FORCE: "1"
  RAILS_ENV: "test"

aliases:
  ll: "ls -la"
  gs: "git status --short"
  gd: "git diff --color=always"
  be: "bundle exec"
  t: "bundle exec ruby -Itest"
```

### Runtime settings

`ekwsh` accepts these top-level runtime settings:

| Setting | Default | What it does |
| --- | --- | --- |
| `shell` | `/bin/sh` | Absolute path to the POSIX-compatible shell used with `-c`. Invalid or relative paths fall back to `/bin/sh`. |
| `timeout_seconds` | `300` | Maximum runtime for one `capture` command. |
| `max_output_bytes` | `1048576` | Maximum output retained for one `capture` command. |
| `history_limit` | `1000` | Maximum persisted shell history entries per workspace. |

When a captured command exceeds `timeout_seconds`, `ekwsh` terminates it and reports the timeout. When captured output exceeds `max_output_bytes`, `ekwsh` terminates the command, keeps bounded output, and reports the output limit. Interactive commands are unbounded; Ctrl-C is forwarded to the child. Press Ctrl-C during a captured command to cancel its Kward worker and return to the shell prompt.

### Environment variables

`env` values are applied when shell mode starts, after Kward's conservative color defaults.

Keys must look like environment variable names:

```text
A_Z, digits after the first character, and underscores
```

Invalid keys are ignored. Values are converted to strings. Nil values are ignored.

Configured env is useful for local preferences such as:

```yaml
env:
  FORCE_COLOR: "1"
  BUNDLE_WITHOUT: "production"
  RAILS_ENV: "test"
```

For one shell session, you can also use the built-in `export` command:

```sh
export FORCE_COLOR=1
```

### Aliases

Aliases expand the first word of a command once.

With this config:

```yaml
aliases:
  ll: "ls -la"
  t: "bundle exec ruby -Itest"
```

these commands run as:

```sh
ll lib
# runs: ls -la lib

t test/test_ekwsh.rb
# runs: bundle exec ruby -Itest test/test_ekwsh.rb
```

Aliases are intentionally simple:

- only the first word is expanded,
- aliases do not recursively expand,
- built-ins win over alias names,
- aliases are not shell functions,
- aliases are global for now.

List configured aliases inside `ekwsh`:

```sh
alias
```

Show specific aliases:

```sh
alias ll gs
```

Aliases also appear in command-name Tab completion inside `/shell` and after the normal composer's `!` prefix. Leading-`!` commands expand the same configured alias once, but do not share aliases created at runtime inside a `/shell` session. Because `!command` is always interactive, Kward removes a leading `capture` or legacy `pty` marker from an expanded alias before running it.

## Interactive PTY commands

External commands entered inside `/shell` own an interactive PTY by default:

```sh
git log
vim README.md
ruby
ssh example.com
```

Kward forwards your keyboard input to the process and streams its output directly to the terminal. This lets tools such as `less` receive keys like Space, `/`, `n`, and `q` normally. When the command exits, Kward restores its prompt and records only a short session summary in the transcript instead of raw full-screen terminal control output.

The older `/pty <command>` slash command and shell `pty <command>` built-in remain available for compatibility. Inside `/shell`, they inherit the embedded shell's current directory and environment just like an ordinary external command.

## Captured commands

Use `capture <command>` inside `/shell` when output should remain in Kward's transcript:

```sh
capture git status --short
capture bundle exec ruby -Itest test/test_ekwsh.rb
```

Captured commands run under a minimal PTY so terminal-aware tools can detect TTY output and terminal width, but keyboard input is not forwarded. The configured timeout and output-size limit apply to captured commands. ANSI output is transcript-sanitized, and Ctrl-C cancels the captured worker through Kward.

From the normal composer, `/capture <command>` provides the same bounded one-shot behavior using the active workspace root. Use `!command` for an interactive one-shot command.

## `/shell` versus `!command`

Kward has two ways to run local commands yourself:

```text
!git status --short
```

runs one command in an interactive PTY directly from the normal composer. When `!` is the first character, press Tab to complete shell commands and paths:

```text
!git sta<Tab>
!cat lib/kwa<Tab>
```

This completion uses the active workspace root, command `PATH`, and aliases configured in `ekwsh.yml`. Configured aliases expand once for submitted `!command` input, including any trailing arguments. Runtime state from an open `/shell` session—such as its current directory, exported variables, or aliases created with the `alias` built-in—is not shared; `!command` remains a one-shot command. Use `/capture <command>` instead when its output should be bounded and retained in Kward's transcript.

```text
/shell
```

starts an embedded command mode for several commands with persistent shell state, aliases, completion, and per-tab shell context.

Use `!command` for one-offs. Use `/shell` when you expect to run several commands in a row.

## Limitations

`ekwsh` is deliberately not a full interactive terminal.

Current limitations:

- interactive command output is visible in terminal scrollback but only the command and exit summary are durable in Kward's transcript,
- interactive commands have no automatic timeout or output-size limit,
- no job control; a stopped child is terminated so it cannot strand the terminal,
- no persistent shell functions,
- no shell startup file sourcing,
- no native readline from your login shell,
- captured `/shell` command output is transcript-sanitized rather than treated as a full terminal UI.

External `/shell` commands use interactive PTY passthrough. Kward does not emulate or retain their full-screen terminal state.
