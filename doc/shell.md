# Embedded shell

Kward lets you run your own shell commands without leaving the interactive TUI. Choose the workflow that matches what you are doing:

- **For one quick command, use `!command`.** It runs from the active workspace and returns you to the normal composer when it finishes.
- **For a longer stretch of shell work, use `/shell`.** It keeps its directory, environment, aliases, and history between commands.
- **To ask Kward for help from inside `/shell`, prefix the request with `?`.** It can inspect the latest shell output, run an explicitly requested state change, or prepare a command in the shell prompt for your confirmation.
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

When an inline command exits without reading input, safe output is mirrored into the transient transcript view so a repaint cannot hide it. Carriage-return and horizontal-cursor progress redraws are reduced to their final visible lines, while an unterminated synchronized-output update is closed before Kward redraws. If the child reads input, Kward retains only output captured before the first forwarded input byte; this prevents echoed passwords, OTPs, or other input from entering tab state. Output from one-off commands is never added to the AI conversation or sent to the model.

Shell output can leave transient text in the transcript area. **After the command finishes, press Ctrl+L to redraw the durable conversation and clear that transient `!command` output.** While an interactive command owns the terminal, the composer remains frozen and ordinary keyboard input belongs to the child process. Kward's tab shortcuts are intercepted separately; switching tabs detaches the command and lets it continue in the originating tab's bounded background state.

Configured `kwshrc` aliases also work after `!`:

```sh
alias glog='git log --decorate --stat --graph'
```

```text
!glog
```

An alias that resolves to `kward edit <filename>` opens Kward's integrated editor in the current session instead of starting a nested Kward process:

```sh
alias vibe='kward edit'
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

## Ask the shell agent

While `/shell` is active, start a submitted line with `?` to ask the transient shell assistant:

```text
? why did the last command fail?
? show me which process is listening on port 3000
? prepare a command to find Ruby files changed today
```

The assistant receives the current shell directory, the last command, its exit status, and bounded output from that command. Output is sent to the model only because you explicitly asked with `?`; it is sanitized and bounded before being included, and shell-agent turns are not added to the normal session history.

If you explicitly ask the assistant to change shell state, it can use the active shell session:

```text
? cd into test
? set RAILS_ENV to test
```

For a suggestion or prepared command, the assistant uses `prepare_shell_command`. The command is placed in the shell composer but is not run until you press `Enter`. Running a command directly and preparing one are deliberately separate actions.

If you explicitly ask it to open an existing workspace file, the assistant uses `open_editor` to open Kward's integrated editor. Opening the editor does not modify or save the file.

The shell assistant cannot safely run commands that require terminal input. Ask it to prepare those commands instead. The local `/shell` session keeps one interactive shell process alive, so directory changes, variables, functions, aliases, and other shell state persist between commands. The one-off `!command` and `/capture` workflows remain separate. SSH remains available through the normal interactive PTY handoff, but shell-agent prompting resumes after that SSH session exits.

## Interactive and captured commands

External commands inside `/shell` are interactive by default:

```sh
git log
vim README.md
ruby
ssh example.com
```

Kward gives each command the terminal, forwards keyboard input, and restores the shell prompt when the command exits. Interactive commands inherit your normal pager configuration, so commands such as `git log` can open `less` in full-screen mode. Kward suppresses Git paging only for noninteractive shell-agent and `capture` executions. It prints the submitted command but no PTY start message or exit-status summary. The line-oriented Git commands `git fetch`, `git ls-remote`, `git push`, `git remote`, and `git status` keep the shell prompt visible as a frozen display. Safe, line-oriented output from commands that did not read keyboard input is kept in the transient transcript view; full-screen and genuinely interactive output stays terminal-owned.

Use `capture` inside `/shell` when you want ordinary, readable output in Kward's transcript area instead of direct terminal control:

```sh
capture git status --short
capture bundle exec ruby -Itest test/test_kwsh.rb
```

An `kwsh` `capture` command:

- does not receive keyboard input,
- uses kwsh's built-in timeout and output-size limits,
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

Shell commands use a separate, workspace-scoped history rather than the normal chat-prompt history. The shell-history limit is a built-in kwsh default.

Kward's tab shortcuts work at the shell prompt and while a shell command is running. Switching tabs detaches the running command instead of interrupting it; bounded output and completion state remain owned by the originating tab and are restored when you return. While detached, the command no longer receives terminal input. Explicit cancellation or shutdown still terminates detached work. Bounded output from shell-agent `?` turns is also retained in the tab's transient runtime view, so it is restored when you switch away and back without being added to session history. Ctrl+L clears this transient shell and shell-agent output.

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

The persistent `/shell` process handles these commands in-session so their state can persist:

| Built-in | What it does |
| --- | --- |
| `cd [dir]` | Change the shell directory. Supports `cd`, `cd -`, and relative paths. |
| `pwd` | Print the shell directory. |
| `export KEY[=value]` | Set an environment variable. `export` and `export -p` list variables. |
| `source <file>` / `. <file>` | Parse and apply aliases and exports from an rc file immediately. |
| `unset KEY` | Remove an environment variable. |
| `alias [name]` | List, inspect, or create aliases. |
| `unalias name` / `unalias -a` | Remove aliases. |
| `capture <command>` | Run with bounded, sanitized transcript output. |
| `pty <command>` | Compatibility spelling for interactive terminal handoff. |
| `clear` | Clear the visible transcript. |
| `exit` / `logout` | Leave shell mode. |

Built-ins take precedence over aliases and executables.

## Configure kwsh

Global shell configuration lives in these optional rc files, loaded in order:

```text
~/.kward/kwshrc
~/.kwshrc
```

When `KWARD_CONFIG_PATH` selects another main config file, Kward reads the first file beside that config file instead. The later file overrides earlier aliases and exported variables with the same names. The rc format currently supports declarative `alias`, `export`, and `source` directives:

```sh
alias ll='ls -la'
alias gs="git status --short"
export BUNDLE_WITHOUT=production
export PATH="$HOME/bin:$PATH"
source ~/.kward/kwsh-aliases
```

`source` reads another rc file without executing it; relative paths in rc-file directives are resolved from the file containing the directive. When entered as a `/shell` builtin, the path is resolved from the current shell directory and its aliases and exports are applied immediately, without restarting Kward. Unsupported shell scripting is ignored for now.

The transient shell assistant normally follows the active conversation's model and reasoning effort. Configure it in the main JSON file:

```json
{
  "shell": {
    "agent": {
      "provider": "openrouter",
      "model": "openai/gpt-5.6-sol",
      "reasoning_effort": "none"
    }
  }
}
```

The optional `provider` uses the lowercase configuration IDs listed in [Model providers](providers.md). When omitted, the shell assistant follows the active conversation. If a provider is explicitly configured without a model or reasoning effort, Kward uses that provider's defaults instead of inheriting the active conversation's values.

Override those settings with environment variables:

```sh
export KWSH_PROVIDER="openrouter"
export KWSH_MODE="openai/gpt-5.6-sol"
export KWSH_REASONING="none"
```

Environment variables take precedence over the JSON settings, and empty values are ignored.

### Runtime defaults

These runtime settings are built into kwsh and are not configurable through rc files:

| Setting | Default | What it does |
| --- | --- | --- |
| `shell` | `/bin/sh` | Absolute executable path for the persistent `/shell` process and interactive shell commands. |
| `timeout_seconds` | `300` | Maximum runtime for one captured or shell-agent command. |
| `max_output_bytes` | `1048576` | Maximum output retained for one captured or shell-agent command. |
| `history_limit` | `1000` | Maximum shell-history entries per workspace. |

Invalid or relative `shell` paths fall back to `/bin/sh`. These timeout and output limits apply to `capture` inside `/shell` and shell-agent commands, not user-owned interactive commands or the separate `/capture` slash command.

### Environment

`export` values from rc files are applied when `/shell` starts and are also available to leading-`!` commands. Keys must be valid environment-variable names; invalid keys are ignored. Values support shell quoting and simple `$VAR`/`${VAR}` expansion.

Kward also supplies conservative terminal defaults:

```sh
export CLICOLOR=1
export COLORTERM=truecolor
export TERM=xterm-256color  # only when TERM is missing or dumb
```

It does not force color. Set `FORCE_COLOR`, `CLICOLOR_FORCE`, or a command-specific option such as `--color=always` when needed.

When rbenv is available, Kward adds its shims and bin directories to `PATH` and supplies `RBENV_ROOT` if it was missing before starting `/shell`. The configured interactive shell may also load its normal startup files.

### Aliases

Aliases replace the first command word once and append any remaining arguments:

```sh
alias ll='ls -la'
alias t='bundle exec ruby -Itest'
```

```sh
ll lib
# runs: ls -la lib

t test/test_kwsh.rb
# runs: bundle exec ruby -Itest test/test_kwsh.rb
```

Configured aliases work inside `/shell` and after `!`. Aliases created with the `alias` built-in belong only to the current `/shell` session and are not shared with one-shot `!command` input.

For compatibility with older configs, Kward removes a leading `pty` or `capture` mode marker when a configured alias is invoked through `!`, because `!command` is always interactive.

Aliases are intentionally simple: they do not expand recursively and are not shell functions. Use `alias` to list them, `alias name=value` to create a runtime alias, and `unalias` to remove one.

## Terminal output and safety

Interactive commands write directly to your terminal so full-screen tools can work. When a command does not read keyboard input and emits only line-oriented text plus safe color sequences, Kward mirrors that output into the transient transcript view after the command exits. Other interactive output is not sanitized and may contain terminal control sequences, so run only commands you trust with terminal access. Safe bounded output is included in a shell-agent request only when you explicitly use `?`; it is never sent to the model for ordinary shell commands.

Commands run with `capture` inside `/shell` preserve safe ANSI color and style sequences while removing cursor movement, clear-screen controls, title changes, alternate-screen controls, and similar sequences that could damage the TUI transcript.

## Limitations

The local `/shell` session is persistent, but it is not a complete terminal emulator or a remote-shell protocol:

- the one-off `!command` and `/capture` workflows do not share `/shell` state,
- shell state is held by the live process and is not serialized across Kward restarts,
- a stopped or unresponsive command can still require Ctrl+C or shell-session cleanup,
- full-screen terminal state is not retained after an interactive command exits,
- while an interactive SSH session owns the terminal, Kward cannot safely intercept `?` or provide remote cwd/completion context; shell-agent prompting resumes after SSH exits,
- safe line-oriented output may remain in the transient TUI transcript; only bounded safe output from an explicit `?` request enters the transient shell-agent context and none of it is added to the normal session history.
