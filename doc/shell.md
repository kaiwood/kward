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

## Write native kwsh scripts

`/shell` now interprets a small POSIX-style language in kwsh itself. It does not send your program to Bash or `/bin/sh`, and it is **not a fully POSIX-conforming shell**. The one-off `!command`, `/capture`, and ordinary model shell tools keep their existing execution paths.

Define a function, then use it in later commands:

```sh
check_files() {
  for file in "$@"; do
    if [ -f "$file" ]; then
      printf 'Found: %s\n' "$file"
    else
      printf 'Missing: %s\n' "$file" >&2
      return 1
    fi
  done
}

check_files README.md Gemfile || printf '%s\n' 'Some files are missing'
```

When a block or quote is incomplete, the prompt changes to `Shell ... >` and collects more lines. No part of that submission runs until it parses successfully. Ctrl+D leaves shell mode; normal execution cancellation and tab detachment still apply once a program is running.

Save a program in a file and run it **inside `/shell`**:

```sh
kwsh scripts/check.kwsh README.md Gemfile
```

The script receives `$0`, `$1`, `${10}`, `$#`, and `"$@"`. It runs in a separate native interpreter process, inheriting exported variables and the current directory without changing the caller's variables, functions, or directory. The gem also installs a standalone `kwsh` executable using the same native interpreter, without loading the coding agent:

```sh
kwsh scripts/check.kwsh README.md
kwsh -c 'printf "%s\n" "$1"' example argument
kwsh -n scripts/check.kwsh             # syntax check without execution
printf 'printf hello\n' | kwsh -s
```

From a checkout, use `ruby exe/kwsh`. Standalone stdin processing leaves each command's input available to `read` and external programs; it does not read the entire input stream ahead of execution. Interactive terminal composition remains a Kward `/shell` feature.

### Supported syntax

- Comments, newlines, `;`, single/double quotes, dollar-single-quotes (`$'line\n'`), and backslash escaping.
- Assignments, `$name`, `${name}`, `$?`, `$$`, positional parameters, `set --`, and `shift`. Parameter operators support defaults, assignment, error checks, alternate values, lengths, and prefix/suffix pattern removal.
- `export` and `unset`; ordinary assignments stay private to kwsh unless exported. `NAME=value command` supplies a temporary environment.
- `&&`, `||`, `!`, concurrent pipelines, brace groups and `( commands )` subshells. Pipeline stages and subshells isolate state. Pipeline status comes from the last stage unless `set -o pipefail` is enabled.
- `if` / `elif` / `else`, `case`, `for`, `while`, `until`, functions, `return`, `exit`, and multilevel `break` / `continue` (for example, `break 2`).
- `<`, `>`, `>>`, `<>`, `>|`, here-documents (`<<` / `<<-`), descriptor duplication, and closing on descriptors 0–9. Redirections apply left to right.
- Ordinary `*`, `?`, and bracket filename patterns, `~` / `~/...`, and field splitting with default, custom, or empty `IFS`. Quote variables and use `"$@"` to preserve argument boundaries. `"$*"` joins arguments with the first character of `IFS` (a space when unset).
- `read [-r] [-d delimiter] variable...`, including EOF status, backslash continuation, and multiple destination variables.
- Persistent `cd`, `pwd`, aliases, and direct executable lookup through `PATH`. Utilities such as `printf`, `test` / `[`, `grep`, and `cat` come from the operating system.

### Handle defaults and process input

Use parameter operators to avoid repetitive tests:

```sh
output=${OUTPUT_DIR:-./build}    # use a default when unset or empty
: "${MODE:=development}"        # also assign the default
: "${PROJECT:?set PROJECT}"     # stop this submission if PROJECT is missing
printf '%s\n' "${#PROJECT}"      # character count
file=src/example.rb
printf '%s\n' "${file##*/}"      # example.rb
printf '%s\n' "${file%.rb}"      # src/example
```

The `-`, `=`, `?`, and `+` operators test whether a parameter is unset. Adding `:` also tests for an empty value. `${name:+word}` substitutes `word` only when the parameter is set and nonempty. Defaults and alternate values may contain nested parameter or arithmetic expansions; unused operands are not evaluated. `:=` can assign ordinary variables, not special or positional parameters. A `:?` error stops the current submission before its command runs, but leaves the interactive session usable.

For pattern removal, `#` / `%` remove the shortest matching prefix / suffix; `##` / `%%` remove the longest. Quote a wildcard **inside** the operator's operand to make it literal: `${file#'*/'}` does not remove a path component. Double-quoting the whole expansion preserves its result without disabling the pattern.

Read a file without losing spaces, backslashes, or its final unterminated line:

```sh
while IFS= read -r file || [ -n "$file" ]; do
  case "$file" in
    *.rb|*.rake) printf 'Ruby: %s\n' "$file" ;;
    '')         continue ;;
    *)          printf 'Other: %s\n' "$file" ;;
  esac
done < files.txt
```

`case` takes the first matching clause. Patterns support `*`, `?`, bracket ranges, negation, and character classes such as `[[:digit:]]`; unlike filename expansion, these patterns can match slashes and leading dots. Quoted pattern characters are literal. An optional `(` before each pattern list and an empty clause body are accepted; Bash fall-through terminators are not yet supported.

`read -r` preserves backslashes. Without `-r`, backslashes escape the next character and backslash-newline continues a logical line. `read` returns 0 after a newline, 1 at EOF (still assigning any partial line), and greater than 1 for an error. With several variables, the final variable gets the remaining unsplit text, with surrounding IFS whitespace removed, following POSIX.1-2024. `read -d delimiter` uses the first byte as the delimiter; an empty delimiter reads NUL-separated records. `-r` and `-d` may be combined. `read -a array` stores split fields in an indexed array; prompt and timeout read options remain unsupported.

Unset `IFS` uses space, tab, and newline. Empty `IFS` disables splitting. Non-whitespace separators such as `:` preserve empty fields between adjacent separators. A prefix assignment such as `IFS= read -r line` applies only to that command; it does not replace the session's `IFS`. `read` consumes only its own logical line, leaving input for the next command. Use redirection or a pipe when asking the shell agent to run it; terminal-input commands should be prepared for you instead.

### Calculate with integer arithmetic

Use `$((expression))` to substitute a calculated integer:

```sh
echo $((5 + 2))                 # 7
value=5
echo "Result: $((value + 2))"    # Result: 7
value=$((value + 1))            # update a counter
```

Arithmetic supports arithmetic, comparison, logical and bitwise operators, shifts, the conditional `?:`, assignments and compound assignments, comma expressions, prefix/postfix `++` / `--`, and right-associative `**`. Decimal, octal (`010`), and hexadecimal (`0x10`) integers work. Variables can hold arithmetic expressions; cycles are errors, and those values are parsed only as arithmetic, never shell commands. Unset or empty variables count as zero unless `set -u` applies. Division truncates toward zero. Logical operators and conditionals evaluate only the selected operand.

Use `((expression))` as a command (zero means failure, nonzero means success), or `for ((init; condition; update)); do …; done` for a counter loop.

Prefer adjacent `))` for portable syntax. As a kwsh convenience, spaces or tabs may separate the final closing parentheses: `echo $((5 + 2) )` also prints `7`. This extension applies only to arithmetic delimiters; it does not rewrite literal text or allow other tokens or newlines between the closers. Single quotes and an escaped `$` keep the expression literal. Incomplete expressions can continue on the next input line.

Arithmetic is bounded to 4,096 expression bytes, 100 nesting levels, and 4,096-bit integers/results. Negative exponents and negative or oversized shift counts are errors. These bounds are intentional differences from Bash machine-integer overflow behavior. Nested substitutions inside arithmetic and arithmetic array references are not yet supported; expand into a scalar variable first. Evaluation never invokes Ruby `eval` or another shell.

### Capture output and connect programs

```sh
revision=$(git rev-parse --short HEAD)
summary="$(printf '%s' "$revision")"
cat <(printf 'generated input\n')
printf 'generated output\n' > >(cat)

cat <<EOF
Revision: $revision
EOF
```

Command substitutions (`$(...)` and legacy backticks) run native parsed programs in an isolated process. They remove trailing newlines, retain interior newlines, and respect surrounding quotes. Assignment-only commands report the last substitution's status. Capture is limited to 16 MiB; oversize output and NUL bytes are explicit errors, not silently truncated values. Substitution children are cleaned up on cancellation.

Process substitutions use inherited `/dev/fd` pipes, owned by the current simple command. Both `<(program)` and `>(program)` work on the supported Unix hosts. Endpoints are closed and children reaped at command completion. kwsh waits for these children before reporting completion, unlike Bash's often-asynchronous process-substitution completion. Do not store these descriptor paths for later commands. Process substitution outside simple commands is not yet supported.

Here-documents expand parameters, command substitutions and arithmetic unless the delimiter is quoted (`<<'EOF'`). `<<-` strips leading tabs, not spaces. Input is stored in an immediately unlinked temporary file, avoiding pipe-buffer deadlocks and persistent temporary content.

### Use arrays, conditions, and generated arguments

```sh
files=(README.md "notes with spaces.md")
files[4]=CHANGELOG.md
printf '%s\n' "${files[@]}"          # retain each element's boundaries
printf 'Count: %s\n' "${#files[@]}"

declare -A metadata
metadata=([language]=Ruby [owner]="Kai Wood")
printf '%s\n' "${metadata[owner]}"

for ((i=0; i<2; i++)); do
  [[ ${files[i]} == *.md ]] && printf '%s\n' "${files[i]}"
done

printf '%s\n' report-{draft,final}.{md,txt} item-{01..03}
shopt -s globstar
printf '%s\n' **/*.rb
```

Indexed arrays are sparse, accept arithmetic indices and negative indices relative to the greatest index, and expand in index order. Associative arrays require `declare -A`. Use `"${array[@]}"` for separate arguments, `"${array[*]}"` to join with IFS, and `${!array[@]}` for keys. `unset 'array[index]'` removes an element. Arrays remain private shell state, not environment strings. Declarations accept `declare -a/-A name=(...)` or separate declaration and assignment. `array+=(...)` appends elements, `array[index]+=text` appends to one value, and `read -a array` reads split fields. Local arrays, namerefs, alternate associative key/value-list syntax, and array prefix environments are not implemented.

`[[ … ]]` avoids splitting and filesystem globbing. It supports string and numeric comparisons, common file tests, pattern matching with `==` / `!=`, parentheses, negation, and lazy `&&` / `||`. Quoting the pattern makes it literal. `=~` accepts regular expressions and sets indexed `BASH_REMATCH` captures. It uses Ruby's engine with a 100 ms timeout, so it is not an exact Bash/POSIX ERE implementation. Put Boolean operator boundaries around a regex operand in separate words.

Brace expansion runs before substitutions and only on unquoted source text. It supports nested choices and numeric/letter sequences, with a 4,096-word and 32-level bound. A variable containing `{a,b}` stays literal. Recursive globbing is opt-in with `shopt -s globstar`, as in Bash; `shopt -u globstar` disables it. Other `shopt` options are not implemented.

### Manage script state

- `. ./library.kwsh [args...]` executes a native library in the current shell; supplied positional arguments are restored afterward. This is separate from declarative `source` in the prompt.
- `readonly name=value`, `unset -f function`, `command [-v|-V|-p]`, and `getopts` operate on interpreter state.
- Explicit `eval` uses the native parser, not Ruby evaluation or a system shell. Treat its argument as executable source, not data.
- `umask` accepts octal and `u/g/o` symbolic permissions. It affects redirected files and external children without changing the host process's lasting mask.
- `cd` and `pwd` support `-L` / `-P`.
- `set` supports `-a`, `-e`, `-f`, `-n`, `-u`, `-x`, `-C`, their `+` inverses, named `-o` options, and `pipefail`. `set -n` checks standalone scripts without execution and is ignored by interactive `/shell`. `set -x` deliberately writes expanded commands to stderr; do not enable it around secrets. Command substitution clears inherited `errexit`, matching Bash's default behavior.

### Remaining compatibility limits

This is **not yet a fully POSIX- or Bash-conforming shell**. Background `&`, jobs/`wait`, traps, `exec`, additional builtin options, and complete locale, alias, expansion and shell-invocation semantics remain unfinished. Executable text without a shebang still fails rather than falling back to another shell; use `kwsh file` or an explicit native shebang. Explicitly requested executables with another interpreter's shebang still use that interpreter.

`capture`, `pty`, `clear`, declarative `source`, and `kward edit` remain prompt conveniences rather than scripting builtins. Aliases still expand complete commands at execution time, not POSIX tokens. `kwshrc` stays non-executing.

The persistent shell and shell-agent API remain TUI-only. RPC/Pan still report that session capability unsupported. The standalone executable can be invoked as an ordinary external program through existing sandboxed command tools; it does not bypass their permission, cancellation, or sandbox boundaries.

### Compatibility roadmap

Native scripting is being extended in tested stages, targeting POSIX.1-2024 plus Bash-compatible behavior for the requested extensions. This is a roadmap, **not a claim that the remaining features already work**:

- [x] Parameter operators, `case`, `read -r/-d`, and custom `IFS`.
- [x] Subshells, nested command substitution, and bounded output capture.
- [x] Here-documents, `<>` / `>|`, and descriptors 0–9.
- [x] Native dot-sourcing, `getopts`, `readonly`, `command`, `eval`, and `umask`.
- [x] Arithmetic operators, increment/decrement, exponentiation, and arithmetic loops, within documented bounds.
- [x] Initial indexed/associative arrays, `[[ … ]]`, process substitution, brace expansion, and opt-in globstar.
- [x] Standalone file/command/stdin modes, dollar-single-quotes, and the documented `set` options.
- [ ] Traps, asynchronous jobs, `wait`, job control, and `exec` lifecycle integration.
- [ ] Remaining array/conditional forms, nested arithmetic substitutions, named-user/assignment-context tilde expansion, builtin flags, and special parameters.
- [ ] POSIX alias tokenization, incremental script-file execution, command lookup/error rules, and executable-text handling.
- [ ] Full conformance coverage. Ruby character classes, codepoint ranges and globbing do not implement all locale collation/equivalence rules; regular expressions and bounded arithmetic are not exact Bash equivalents.

Language and state transitions remain native; implementing these features must not introduce a Bash or `/bin/sh` fallback. Declarative `kwshrc` loading and ordinary model/RPC command isolation remain separate contracts.

References: [POSIX Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html), [POSIX read](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/read.html), [Bash parameter expansion](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html), and [Bash arrays](https://www.gnu.org/software/bash/manual/html_node/Arrays.html).

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

The shell assistant cannot safely run commands that require terminal input. Ask it to prepare those commands instead. The local `/shell` session keeps one native kwsh interpreter process alive, so directory changes, variables, functions, aliases, and other shell state persist between commands. The one-off `!command` and `/capture` workflows remain separate. SSH remains available through the normal interactive PTY handoff, but shell-agent prompting resumes after that SSH session exits.

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
| `shell` | `/bin/sh` | Executable for the separate one-off command path; persistent `/shell` now uses the native kwsh interpreter. |
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
