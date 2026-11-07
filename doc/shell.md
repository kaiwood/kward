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

Standalone kwsh accepts inherited file descriptors 3–9 as well as standard input, output, and error. For example, from a parent shell:

```sh
kwsh -c 'cat <&3; printf "done\n" >&9' 3<input.txt 9>status.txt
```

Inherited descriptors support duplication, persistent `exec` redirection, and explicit closing. They reach child commands, native scripts, and executable-text fallback. The maximum supported shell redirection descriptor is 9. Discovery happens only at the standalone executable boundary; embedded runtimes and hosted `/shell` never discover Kward's private sockets or other open handles. Caller-supplied runtime descriptors remain borrowed unless ownership is explicitly transferred. This does not change RPC/Pan shell capabilities or sandbox policy.

From a checkout, use `ruby exe/kwsh`. Standalone stdin processing leaves each command's input available to `read` and external programs; it does not read the entire input stream ahead of execution. The rich interactive composer remains a Kward `/shell` feature. Standalone `kwsh -i` provides a plain line-oriented prompt, also selected automatically when reading commands from stdin with stdin and stderr attached to a terminal.

Startup sets `PPID` to the shell's parent process ID and `OPTIND` to `1`, even if those variables were inherited with different values. Subshells and command substitutions retain the current values instead of reinitializing them. `OPTIND` is not exported by default.

Standalone startup preserves an inherited `PWD` when it names the current directory with an absolute pathname and has no `.` or `..` components, including valid symlink-based logical paths. Otherwise it uses the physical pathname (`pwd -P`). Valid inherited paths beyond `PATH_MAX` are also retained when the filesystem can resolve them; if permissions prevent determining the physical pathname, POSIX leaves the value unspecified. Hosted `/shell` continues to use its explicit workspace root rather than adopting inherited `PWD`.

For file execution, `$0` is the command-file operand. With `-c`, an explicit command name becomes `$0`; otherwise, and when reading stdin, `$0` comes from the executable invocation (for example, `exe/kwsh` when launched with `ruby exe/kwsh`), not a fixed `kwsh` string. A leading single `-` ends option processing and is ignored before selecting operands:

```sh
kwsh - scripts/check.kwsh README.md      # read the file, not stdin
kwsh -c - 'printf "%s:%s\n" "$0" "$1"' check README.md
printf '%s\n' 'printf "%s\n" "$1"' | kwsh -s - README.md
```

A lone `kwsh -` still reads commands from stdin. Do not combine this leading `-` with `--`; POSIX leaves that combination undefined.

For a standalone interactive session:

```sh
kwsh -i
ENV="$HOME/.kwsh-env" kwsh -i
kwsh -ec 'printf "%s\n" "$1"' example argument
```

Interactive startup parameter-expands `ENV` and executes the named native file when it exists. Non-interactive invocations ignore `ENV`; startup loading is also disabled when real and effective user or group IDs differ. This executable startup file is separate from declarative `kwshrc`. `PS1` and `PS2` support parameter expansion; command substitutions in startup path or prompt text are rejected. Errors leave the prompt usable, and input is read without consuming a following command's stdin. Shell options may be grouped and may follow `-c` or `-s`. Standalone command history and `fc` are available; vi/emacs line-editing modes remain separate milestones.

Executable text files without a shebang also run natively when invoked from kwsh:

```sh
cat >hello <<'EOF'
printf 'Hello, %s\n' "$1"
EOF
chmod +x hello
./hello captain
```

After the operating system reports an executable-format error (`ENOEXEC`), kwsh interprets the file in a fresh native shell environment. This also works through `PATH`, `command`, and `exec`; arguments, exported variables, the working directory, redirections, and umask are preserved. The command name is retained as `$0`. Files without executable permission still fail, and a bounded prefix check rejects NUL-containing or ELF-looking binaries. Unsupported syntax remains an error, never a reason to try Bash or `/bin/sh`. An explicit shebang continues to select its named interpreter.

### Supported syntax

- Comments, newlines, `;`, single/double quotes, dollar-single-quotes (`$'line\n'`), and backslash escaping.
- Assignments, `$name`, `${name}`, `$?`, `$$`, positional parameters, `set --`, and `shift`. Parameter operators support defaults, assignment, error checks, alternate values, lengths, and prefix/suffix pattern removal.
- `export` and `unset`; ordinary assignments stay private to kwsh unless exported. `NAME=value command` supplies a temporary environment.
- `&&`, `||`, `!`, concurrent pipelines, brace groups and `( commands )` subshells. Pipeline stages and subshells isolate state. Pipeline status comes from the last stage unless `set -o pipefail` is enabled.
- `if` / `elif` / `else`, `case`, `for`, `while`, `until`, functions, `return`, `exit`, and multilevel `break` / `continue` (for example, `break 2`).
- `<`, `>`, `>>`, `<>`, `>|`, here-documents (`<<` / `<<-`), descriptor duplication, and closing on descriptors 0–9. Redirections apply left to right. Their operands do not undergo field splitting or pathname expansion, so `file="two words"; printf hello >$file` writes one file. Unquoted here-documents remove backslash-newline continuations before recognizing the delimiter.
- Ordinary `*`, `?`, and bracket filename patterns, `~` / `~user/...` (also after assignment colons), and field splitting with default, custom, or empty `IFS`. Quote variables and use `"$@"` to preserve argument boundaries. `"$*"` joins arguments with the first character of `IFS` (a space when unset).
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

`case` takes the first matching clause. Patterns support `*`, `?`, bracket ranges, negation, and character classes such as `[[:digit:]]`; unlike filename expansion, these patterns can match slashes and leading dots. Quoted pattern characters are literal. An optional `(` before each pattern list and an empty clause body are accepted. POSIX.1-2024 `;&` executes the next clause without testing or expanding its patterns; `;;` stops the case. Bash `;;&` re-testing remains unsupported.

`read -r` preserves backslashes. Without `-r`, backslashes escape the next character and backslash-newline continues a logical line. `read` returns 0 after a newline, 1 at EOF (still assigning any partial line), and greater than 1 for an error. With several variables, the final variable gets the remaining unsplit text, with surrounding IFS whitespace removed, following POSIX.1-2024. `read -d delimiter` uses the first byte as the delimiter; an empty delimiter reads NUL-separated records. `-r` and `-d` may be combined. `read -a array` stores split fields in an indexed array; prompt and timeout read options remain unsupported.

New shell invocations initialize `IFS` to space, tab, and newline, ignoring an inherited value. Unset `IFS` uses the same defaults. Empty `IFS` disables splitting. Non-whitespace separators such as `:` preserve empty fields between adjacent separators. A prefix assignment such as `IFS= read -r line` applies only to that command; it does not replace the session's `IFS`. `read` consumes only its own logical line, leaving input for the next command. Use redirection or a pipe when asking the shell agent to run it; terminal-input commands should be prepared for you instead.

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

Arithmetic has no fixed expression-byte limit. Long left-associative chains are evaluated iteratively, preserving operand order and short-circuiting. Leading zeros in integer spellings do not consume precision. Parser/evaluator recursion remains limited to 100 internal levels. Values are checked using Ruby `Integer#bit_length <= 4096`, corresponding to the range `-2**4096` through `2**4096 - 1`; intermediate operands/results must fit too. Division truncates toward zero, and overflow reports an error rather than wrapping. Shift counts must be between 0 and 4096; negative exponents are errors. This exceeds the POSIX signed-long minimum but is not Bash machine-integer behavior. The remaining depth quota is a separate non-conforming safety policy, not an arithmetic precision allowance. Arithmetic expansion accepts parameter operators, command substitutions, backticks, and nested arithmetic, for example `$(( $(printf 2) + $((3 + 1)) ))`. Shell substitutions expand once before integer evaluation; expanded values are never parsed as shell commands. Static expressions are syntax-checked without evaluation; expressions containing substitutions are validated after expansion at execution time. Arithmetic array references and substitutions in the Bash-style `((...))` command/loop forms remain unsupported. Evaluation never invokes Ruby `eval` or another shell.

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
- `LINENO` reports the current source line, including commands in functions and sourced files. Explicitly assigning or unsetting it disables automatic tracking for that interpreter.
- `readonly name=value`, `unset -f function`, `command [-p] [-v|-V]`, and `getopts` operate on interpreter state.
- Explicit `eval` uses the native parser, not Ruby evaluation or a system shell. Treat its argument as executable source, not data.
- `umask [-S] [--] [mask]` accepts octal and symbolic permissions, including copies (`g=u`) and sequential operations (`g=u-w`). Setting a mask prints nothing, even with `-S`; querying with `-S` prints reusable `u=...,g=...,o=...` permissions. `X` uses the original allowed execute bits; non-permission `s`/`t` bits are ignored. It affects redirected files and external children without changing the host process's lasting mask.
- `cd` and `pwd` support grouped `-L` / `-P` flags and `--` (the last `-L` or `-P` wins). `cd -P -e` returns 1 if the directory changes but its physical pathname cannot be determined; without `-e`, that reporting failure still returns 0. Other `cd -P -e` errors return greater than 1 and leave the directory unchanged; `cd` searches `CDPATH` for eligible relative directory operands. `command -pv` and `command -pV` use the system default utility path without changing the caller's `PATH`. `hash [utility...]` remembers locations, `hash -r` clears them, `type` describes command resolution, and `times` reports shell/child CPU usage.
- `set` supports `-a`, `-b`, `-e`, `-f`, `-h`, `-m`, `-n`, `-u`, `-v`, `-x`, `-C`, their `+` inverses, named `-o` options, and `pipefail`. `set -n` checks standalone scripts without execution and is ignored by interactive `/shell`. `set -x` deliberately writes expanded commands and assignments (including assignment-only commands) to stderr after expansion and before execution; command stderr redirections also capture these traces. Do not enable it around secrets. Command substitution inherits `errexit`, following POSIX rather than Bash's default mode. `-v` echoes source as it is read; `-b` enables interactive job-completion notifications while waiting for input; `-h` remembers literal external commands when functions are defined. `set -` disables verbose and execution tracing.

Assignment and expansion errors, and errors from directly invoked special builtins, stop non-interactive scripts even without `set -e`. Their EXIT trap still runs. In interactive `/shell`, these errors stop the current submission but leave the session usable. Ordinary utility and compound-command redirection failures return a nonzero status without terminating the shell; `command` also suppresses a special builtin's special error-exit behavior. `set -e` adds exit-on-failure behavior while respecting conditional tests, negated pipelines, and non-final AND-OR commands.

### Keep working after a directory rename

The active directory is retained by identity, not just its pathname. A rename does not redirect subsequent commands into a replacement directory at the old name:

```sh
cd build/staging
mv ../staging ../ready
printf 'done\n' >status.txt       # writes in build/ready
pwd -P                          # reports the current physical pathname
```

External commands, subshells, native scripts, `. ./library`, relative redirections and globs continue using that directory. `$PWD` retains the shell's logical spelling until a later directory change; `pwd -L` falls back to physical reporting when that spelling no longer identifies the directory. Logical `cd missing/..` fails rather than silently cancelling the missing component, and non-directory or dangling-symlink components fail too.

If the current directory is removed, pathname reporting can fail, while external execution and `cd -P ..` can still work according to the filesystem's rules. Relative file opens and child directory entry use retained descriptors, without changing Kward's host-process directory. Physical name discovery uses macOS `F_GETPATH` or Linux `/proc/self/fd`; Linux needs `/proc` mounted for name-based operations. These changes do not bypass command sandboxing or expose private handles as shell descriptors.

### Run and control background work

```sh
sleep 2 & first=$!
sleep 1 & second=$!
jobs -l
wait "$second"
wait "$first"
printf 'Last status: %s\n' "$?"
```

`&` starts an isolated asynchronous AND-OR list, including pipelines. `$!` is its waitable leader PID. `wait` with no arguments collects all known jobs and returns zero; with operands it returns the last requested job's status. An unknown or already-collected PID returns 127. Termination by a signal returns `128 + signal number`. Completed statuses are retained until collected; there is a 1,024-job bound.

`jobs` accepts `-l`, `-p`, `-r`, and `-s`. Job selectors include `%1`, `%+` / `%%` (current), `%-` (previous), `%prefix`, and `%?substring`; ambiguous selectors error. `kill [-s signal | -SIGNAL] pid-or-job...` signals a process or an entire job group. `kill -l` lists signal names and translates numbers.

Job control is on by default in `/shell`; standalone scripts can enable it with `set -m`. Ctrl-Z stops a foreground job and returns terminal ownership to kwsh. Terminal modes are saved with the stopped job and restored on `fg`, including for programs that suspend themselves after entering raw mode. Use `bg %1` to continue it in the background, or `fg %1` to return it to the terminal. Without job control, asynchronous input defaults to `/dev/null` unless explicitly redirected.

Hosted jobs remain tab-owned: closing the shell kills its owned groups, including stopped jobs. A forked hosted scope waits for its own background work before reporting completion, keeping descendants owned; standalone scripts do not impose that host-lifecycle rule. In `/shell`, background terminal output is drained and discarded while the prompt is idle so logging cannot block a server after `bg`. Output written during another command can still mix with that command's output. Redirect long-running jobs to files when you need to retain logs, for example `rake docs:serve >docs-server.log 2>&1 &`. Script jobs are separate from Kward's tab-detached foreground-command feature.

### Handle signals and replace a script

```sh
trap 'printf "Finished with status %s\n" "$?"' EXIT
trap 'printf "Received a notification\n"' USR1
kill -USR1 $$
trap - USR1                     # restore the original disposition

exec 3>report.log               # retain a descriptor in shell state
printf '%s\n' ready >&3
exec 3>&-
```

`trap` accepts signal names (with or without `SIG`), numbers, and `EXIT` / `0`. An empty action ignores a signal; `-` resets it to the shell's default. Bare `trap` lists non-default actions, including inherited ignores. `trap -p [--] [signals...]` also reports defaults, so saved output can undo traps added later:

```sh
saved=$(trap -p)
trap 'printf "Interrupted\n"' INT
# Run native commands with the temporary action.
eval "$saved"
```

Subshells and command substitutions reset caught execution actions immediately, but retain the parent's actions for trap inspection until a `trap` command supplies operands. This keeps `saved=$(trap -p)` useful without running the parent's handlers in the child. Non-interactive shells cannot catch or reset signals ignored on entry; interactive shells can override them. Invalid signal names return a nonzero status with a diagnostic, without aborting the rest of a script.

Actions execute as native source at interpreter safe points, preserving the interrupted `$?` unless they explicitly exit. Trapped signals interrupt the `wait` builtin; the action sees `128 + signal number` and runs before an `errexit` exit. When waiting for an ordinary foreground command, actions run after that command finishes. `EXIT` runs once on normal completion, explicit exit, or `errexit`. `KILL` and `STOP` cannot be caught or ignored; default resets are harmless. Ruby reserves `ILL`, `FPE`, `BUS`, `SEGV`, and `VTALRM`: kwsh can report their default dispositions but cannot install actions for them. This remains a conformance limitation.

Standalone interactive kwsh ignores `TERM` and `QUIT` by default. It also ignores `TTIN`, `TTOU`, and `TSTP` while monitoring jobs (and chooses to keep ignoring them with monitoring disabled). `INT` discards unfinished prompt input; while executing a command, an `INT` sent only to the shell does not interrupt that command. Terminal-generated Ctrl+C normally targets the foreground job, whose signal status is returned to the prompt. These shell-only defaults are reset for child commands, native scripts, and executable-text fallback; explicitly ignored signals remain ignored.

In standalone `kwsh`, `exec program args...` uses direct `execve`: it preserves the PID, does not run an EXIT trap on success, and never falls back to `/bin/sh`. `exec -c` clears the child's environment; `-a name` selects argv[0], `-l` prefixes it with `-`, and `--` ends options. Without a program, redirections persist.

A failed `exec` in standalone interactive kwsh reports status 127 (not found) or 126 (other execution failure) and accepts a fresh submission. The failed submission may be abandoned. Successful redirections on that `exec` remain in effect, including input for the next submission; save descriptors first if you intend to restore them:

```sh
exec 8>&1 9>&2
exec ./missing >attempt.log 2>attempt.err
printf 'status=%s\n' "$?"       # still writes to attempt.log
exec 1>&8 2>&9                   # restore output and diagnostics
```

The interpreter restores its internal descriptors, directory, signal handlers, and process mask after failed replacement. Closed standard descriptors may be backed by `/dev/null`, as POSIX permits, so a closed stderr does not break prompt rendering. Non-interactive exec failures still exit. Successful exec still replaces the process with the same PID, including native executable-text fallback.

Standalone startup performs one same-PID re-exec of the trusted Ruby binary to reserve descriptor slots 3–9 away from Ruby's private wake-up handles. The reservation handles are close-on-exec and are not shell descriptors; inherited user descriptors remain available through the explicit shell map. Ruby startup hooks are not rerun by this internal bootstrap. This is not used by hosted workers and does not change RPC/Pan capabilities or sandbox boundaries.

The TUI worker must retain its private control channel. Its hosted `exec` therefore runs the replacement program, reports final state, and ends the logical shell session rather than replacing the protocol process. Hosted child scopes also retain their supervisors so that `exec` cannot abandon background descendants. `USR2` is reserved for hosted shutdown, omitted from that worker's trap listings, and cannot be trapped there; standalone scripts may trap it normally. Closing a tab is forced host cleanup, not a normal EXIT-trap invocation.

### Read aliases and scripts in order

```sh
alias say='printf "%s\n"'
say ready
alias dispatch='say '           # trailing blank enables alias expansion of the next word
alias greeting=hello
dispatch greeting
```

Native aliases expand unquoted command tokens while parsing, before parameter expansion. They may contain operators, refer to other aliases, or shadow builtins; cycles stop at the already-expanded name. Quoted names and names obtained from variables are not expanded. Define aliases in a separate complete input unit before using them: an alias change does not alter commands already parsed on the same line or in a function body. Replacement text shares the input lexer, so quotes and here-document bodies can cross alias boundaries. Expansion is bounded to 100 nested aliases, 65,536 replacement tokens, and 1 MiB of replacement source per parsed input unit.

Alias names accept letters, digits, and `!`, `%`, `,`, `-`, `@`, `_`, including numeric names such as `1`. Use `alias -- '-name=value'` for a name beginning with `-`. `alias` and `alias name` list quoted `name=value` entries, without an `alias ` prefix; prepend `alias -- ` when restoring a listed entry. `command -v` and `type` retain their separate command-description output.

Files, stdin, and explicit native source execute one complete input unit at a time. An error on a later line does not undo earlier commands. Stdin execution does not read ahead of a command that consumes its own input. `source` and `kwshrc` remain declarative and non-executing; `. ./file` now consistently means executable native sourcing in `/shell` as well as scripts.

### Select character and sorting rules

`LC_ALL` overrides category settings; otherwise `LC_CTYPE` and `LC_COLLATE` override `LANG`, defaulting to `C`. Installed libc locales control character counts, bracket classes/ranges, single- and multi-character collating symbols (`[[.a.]]`, `[[.ch.]]` where installed) and equivalence classes (`[[=a=]]`), string ordering, and filename sorting. For example:

```sh
value=é
LC_ALL=C
printf '%s\n' "${#value}"       # 2 bytes
LC_ALL=C.UTF-8
printf '%s\n' "${#value}"       # 1 character, if this locale is installed
```

Unavailable locales and unsupported encodings produce explicit errors. Locale changes use thread-local locale objects, not process-global `setlocale`. Path matching shares the bounded native string matcher; globstar does not descend through symlinked directories or hidden entries. A pathname expansion may visit at most 100,000 directory entries and 100 directory levels. These locale bindings target macOS and Linux.

Multi-character elements are shared by `case`, parameter trimming, and pathname expansion. For example, in an installed Czech locale, `[[.ch.]]` can match the two characters `ch`, and `[c[.ch.]]h` can match either `ch` or `chh`. Matching retains both paths rather than committing to the shorter element. Outside the POSIX locale, range behavior is unspecified by POSIX; kwsh uses the installed collation order. Available elements and primary equivalence classes depend on host libc/locale data. Multi-character symbol names containing glob metacharacters are rejected rather than passed to an unbounded libc wildcard matcher.

Collating-pattern matching uses an iterative, non-recursive search, capped at 1,000,000 transitions/prefix probes and 16 MiB of cumulative candidate bytes per match. Exceeding a bound is an error, not a partial match or silent omission. Ordinary C/POSIX patterns keep the single-character fast path.

### Resource limits and conformance

There is **no unrestricted/conforming standalone mode** yet. The native interpreter deliberately retains the safety policies below in both standalone kwsh and hosted `/shell`. Documenting a policy does not make it POSIX-conforming. In particular, passing the long-arithmetic regression does not close the remaining parser, expansion, or job-limit gaps. These are not configurable via an environment variable or a shell option.

The classification distinguishes **permitted choices** from **system constraints**, **extension policies**, and **additional safety policies affecting POSIX-required behavior**. Sources below are under `lib/kward/shell/`. The inventory covers native interpreter limits and the adjacent shell-host limits; external utilities and the OS can impose further constraints.

| Area / source | Enforced bound | Classification and disposition |
| --- | --- | --- |
| Arithmetic precision (`native_arithmetic.rb`) | `Integer#bit_length <= 4096`; every evaluated intermediate is checked | Permitted precision choice: SCL 2.6.4 allows a signed type larger than signed long. Overflow errors, no implicit wrap or floats. Significant-digit prechecks reject only values already too large for this precision. |
| Arithmetic domains (`native_arithmetic.rb`) | Shift count 0–4096; nonnegative exponent; exponentiation checked before allocating oversized results | Precision/domain choice and extension policy (`**`); preserves integer-only evaluation. |
| Arithmetic parser/evaluator depth (`native_arithmetic.rb`) | 100 internal recursive levels, including recursive variable-value evaluation; cycles rejected | Additional safety policy. Long flat binary chains no longer consume one recursive level per term. Deep otherwise-valid standard arithmetic still can fail. |
| Lexical expansion depth (`native_syntax.rb`) | 100 levels each for arithmetic, parameter, and command/backtick substitution paths | Additional safety policy affecting SCL 2.6; not justified by integer precision or OS limits. |
| Shell grammar depth (`native_syntax.rb`) | 100 internal parsing levels | Additional safety policy affecting standard nested compound commands. |
| Conditional-expression parsing (`native_syntax.rb`) | 100 recursive levels in the `[[ … ]]` parsers | Extension policy; not a portable POSIX conditional syntax. |
| Alias expansion (`native_syntax.rb`) | 100 expansion-provenance levels, 65,536 alias-derived tokens, 1,048,576 cumulative replacement bytes per parser instance | Additional safety policies. Same-name recursion suppression is a separate standard alias rule, not justification for these quotas. |
| Function, dot-source, and eval execution (`native_runtime.rb`, `native_builtins.rb`) | 100 levels each | Additional safety policies affecting otherwise-valid standard programs. |
| Command substitution (`native_substitution.rb`) | 16 MiB captured bytes before removing trailing newlines | Additional safety policy affecting SCL 2.6.3 in both modes. Output is rejected, not silently truncated; child cleanup remains mandatory. Process-substitution pipes do not use this capture buffer. |
| Multi-character collating matches (`native_pattern.rb`) | 1,000,000 accounted steps and 16 MiB cumulative candidate-byte work per match | Additional safety policies affecting SCL 2.14. These are work accounts, not a promise of a 16 MiB live-memory maximum. The matcher remains iterative; ordinary matching has no new fixed input-byte limit. |
| Pathname traversal (`native_glob.rb`) | 100,000 visited directory entries and 100 traversal levels | Additional safety policies for ordinary globs; also extension policies for `**`. Visited entries include nonmatches, so these are not merely result-count limits. |
| Job records (`native_jobs.rb`) | 1,024 active or retained jobs; new jobs fail until records are collected | Additional safety policy. This is not derived from `{CHILD_MAX}` and is not justified merely by POSIX's permission to forget old statuses. |
| PID operands (`native_jobs.rb`) | Absolute numeric value at most 2,147,483,647; at most 10 digits, plus optional minus | Numeric range follows the supported systems' signed `pid_t` ABI. The spelling-length restriction can reject excessive leading zeros and remains an additional policy. |
| Shell descriptors (`native_syntax.rb`, `native_runtime.rb`) | User redirections and duplication use descriptors 0–9 | Permitted implementation maximum: SCL 2.7 requires at least 0–9. Private backup descriptor floors (32) and startup reservations are allocation mechanics, not extra user descriptors. |
| Brace expansion (`native_braces.rb`) | 4,096 generated words, 32 recursive levels, 128 characters per numeric endpoint/step | Extension policies, not restrictions on a required POSIX expansion. |
| Indexed arrays (`native_arrays.rb`) | Index at most `2**31 - 1` | Extension policy; sparse storage does not make this a standard shell limit. |
| Regex condition (`native_condition.rb`) | 0.1-second Ruby regexp timeout for `[[ … =~ … ]]` | Extension policy. This is not a timeout on POSIX `case` patterns. |
| Executable-text detection (`native_process.rb`) | Inspect at most 4,096 bytes for binary-looking content before native ENOEXEC fallback | Permitted heuristic under SCL 2.9.1.6; **not** a script/line-length limit. |
| Physical directory reporting (`native_directory.rb`) | macOS F_GETPATH's 1,024-byte buffer; Linux procfs name discovery | System/API constraints; the retained directory descriptor is separate from successful pathname reporting. |
| Native process and file resources | OS argument/environment size, descriptor/process limits, filesystem limits, available memory/storage, Ruby stack/runtime constraints | Underlying system constraints, not promises that every source fitting a kwsh quota can execute. No Ruby/system-shell eval fallback is introduced. |
| Hosted capture (`kwsh.rb`, `persistent_session.rb`) | Defaults: 1 MiB output and 300-second captured-command timeout; configurable through the existing shell configuration | Host policy only, unchanged. User-owned interactive commands do not get these capture/time limits. Normal model/RPC shell tools keep their own existing sandbox and cancellation policies. |
| Hosted context/preparation/history (`kwsh.rb`, `prompt_session.rb`) | 32,000-byte last-output context and prepared-command bound; default 1,000 history entries | Host/UI policies, not standalone shell-language limits. History remains configurable as documented below. |
| Hosted startup/cancellation (`persistent_session.rb`) | 5-second startup wait, 1-second interrupt/escalation waits, 0.2-second PTY draining window | Host lifecycle policies, unchanged; not standalone execution quotas. |

Fixed IO read chunks (4 KiB for hosted PTY reads, 16 KiB for substitution capture), polling intervals, the sigaction ABI buffer, `read`'s variable-count splitting, and escape widths are **not** cumulative program-size quotas. Dollar-single-quote hex escapes consume up to two digits and octal escapes up to three; longer hex forms are unspecified by POSIX, while `\u`/`\U` consume up to four/eight hex digits as extensions. Input files, here-documents, and ordinary source lines have no newly introduced byte ceiling; removing the arithmetic ceiling does not remove the explicitly listed nesting/work limits.

Authority: [POSIX shell language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html), especially 2.3, 2.6.3/2.6.4, 2.7, 2.9 and 2.14, and [sh input files](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html). The open safety-policy gaps remain tracked separately from Base/UP/XSI feature coverage in `plan/POSIX_REQUIREMENTS.md`.

### Remaining compatibility limits

This is **not yet a fully POSIX- or Bash-conforming shell**. Additional builtin options, arithmetic array references, advanced array forms, and exact Bash/POSIX regular-expression semantics remain outside the implemented subset. `wait -n`, Bash pseudo-traps (`DEBUG`, `ERR`, `RETURN`), XSI `ulimit`, and standalone vi/emacs editing are not implemented.

`capture`, `pty`, `clear`, declarative `source`, and `kward edit` remain prompt conveniences rather than scripting builtins. Native aliases use read-time token expansion; the separate one-off `!` path retains its existing single command-prefix replacement. `kwshrc` stays non-executing.

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
- [x] Signal/EXIT traps, asynchronous jobs, `wait`, terminal job control, and standalone/hosted `exec` lifecycle integration.
- [x] Named-user/assignment-context tildes, `$!`, read-time aliases, and incremental script-file execution.
- [x] Installed-locale character counts, single-character bracket classes/collation, native pathname matching, and locale sorting.
- [x] Native interpretation of executable text after `ENOEXEC`, including standalone `exec` and hosted job ownership.
- [x] Arithmetic-expansion substitutions, POSIX case fall-through, initial IFS, LINENO, and command-reporting precedence.
- [x] Shared-stream aliases, core builtin option combinations, command hashing, CDPATH, times, standalone interactive invocation, and guarded ENV startup.
- [x] Startup PPID/OPTIND, inherited logical PWD validation, invocation-derived `$0`, and leading `-` operand handling.
- [x] Bounded multi-character collation, including mixed brackets, ranges, trimming, and pathname matching.
- [x] Requirement-linked regression cases for quoting, splitting, redirections, continuations, errors, special builtins, invocation, jobs, and locale integration.

The remaining tracks are separate:

- **POSIX verification:** broader independent clause-by-clause audits and platform/locale matrices. The tests below are regression coverage, not certification of every POSIX requirement.
- **Optional utility/editing profiles:** XSI `ulimit` and vi/emacs editing.
- **Bash extensions:** remaining array/conditional forms, arithmetic array references, `wait -n`, pseudo-traps, and exact Bash regex/machine-integer behavior.
- **Remaining shared safety policies:** the resource inventory above includes limits that also affect standalone POSIX behavior; these are open conformance gaps, not just hosted differences.
- **Intentional hosted differences:** reserved shutdown signals, supervised `exec`, tab-owned descendants, and host capture/time limits. Standalone interactive execution does not adopt hosted cleanup or reserve its shutdown signal.

### Verify native shell behavior

Run the focused shell suite without network services:

```sh
ruby -Itest -e '(Dir["test/test_native_shell*.rb"] + %w[test/test_persistent_shell_session.rb test/test_kwsh.rb test/test_shell_prompt.rb]).sort.each { |file| require_relative file }'
```

| Coverage | Tests |
| --- | --- |
| POSIX clause-linked behavior and cross-feature regressions | `test/test_native_shell_posix.rb` |
| Aliases, builtin options, startup identity checks, terminal invocation | `test/test_native_shell_invocation.rb` |
| Deterministic collation paths and work bounds | `test/test_native_shell_pattern.rb` |
| Installed-locale matching, trimming, globbing, and locale restoration | `test/test_native_shell_locale.rb` |
| Script modes, native execution, traps, descriptors, and process ownership | `test/test_native_shell.rb`, `test/test_native_shell_runner.rb`, `test/test_native_shell_descriptors.rb`, `test/test_native_shell_signals.rb`, `test/test_persistent_shell_session.rb` |

Installed multi-character collation tests require Czech or Slovak UTF-8 locale data and explicitly skip when unavailable. Deterministic matcher tests still run everywhere. Use POSIX.1-2024 as the authority when adding cases; Bash and the host `/bin/sh` can help investigate differences but are not conformance oracles. Do not turn implementation-defined or unspecified behavior into a purported universal requirement.

Language and state transitions remain native; implementing these features must not introduce a Bash or `/bin/sh` fallback. Declarative `kwshrc` loading and ordinary model/RPC command isolation remain separate contracts.

References: [POSIX Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html), [POSIX read](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/read.html), [Bash parameter expansion](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html), and [Bash arrays](https://www.gnu.org/software/bash/manual/html_node/Arrays.html), [POSIX wait](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/utilities/wait.html), and [POSIX job control](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/utilities/fg.html), and [Apple newlocale](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/newlocale.3.html).

### Standalone command history

In `kwsh -i`, use `fc -l` to list recent commands, `fc -s old=new` to run the previous command with one replacement, or `fc -e vi` to edit and execute it. Numbers, negative offsets and command prefixes select entries; `fc -lnr 1 10` lists a reversed range without numbers. Replayed commands use the native interpreter, with the same assignments and redirections as `fc`.

History defaults to **512 entries in memory**. For persistence, set `HISTFILE` to a private file before the first prompt (for example in your `ENV` startup file). `HISTSIZE` is a decimal entry count. Both are read once when history is first used; later changes do not reconfigure it. No file is created implicitly under `HOME`. History can contain secrets: do not enable persistence for sensitive sessions.

History files use private JSONL records with stable, increasing numbers. New files are mode 0600; existing files must be regular, owned by the current user, mode 0600, and have one hard link. Symlinks and unsafe/inaccessible files fall back to memory without modifying their permissions. Updates are locked, but simultaneous shells can overwrite each other's snapshots; use separate files for independent terminals. Forked environments do not write their parent's history.

`FCEDIT` is parameter-expanded and names one executable (default `ed`), not shell source or a command plus arguments. Explicit `fc -e editor` overrides it. Edited commands live in a mode-0600 file inside a private temporary directory, removed on completion, failure, or cancellation. A failed/cancelled editor never executes its buffer or adds it to history. As with other temporary files, an uncatchable process kill can leave a private directory behind.

Native `fc` is standalone-only. Kward's hosted `/shell` retains its existing workspace history and composer ownership; RPC does not acquire a terminal editor or history-file API.

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

### Protecting terminal shortcuts

With Ctrl tab bindings, Ctrl+1 through Ctrl+9 stay reserved for Kward, including while a command owns the screen. Kward keeps ownership of keyboard encoding: child Kitty keyboard push/pop/set and xterm `modifyOtherKeys` changes are filtered, and screen switches or terminal resets reassert Kward's encoding. Ordinary child input still uses the existing legacy-key translation; applications requiring their own enhanced keyboard protocol should run outside Kward.

On completion, cancellation, or tab detachment, Kward cancels unfinished terminal controls, leaves the alternate screen, and restores its keyboard, paste, mouse, focus, cursor-key, and rendering modes before redrawing. Fragmented key sequences are buffered within a fixed limit, and shortcuts inside bracketed paste are forwarded as pasted data rather than acted on.

This is best-effort protection, not a terminal sandbox. Ctrl+number still depends on your terminal sending distinguishable modified keys; Kward cannot recover modifiers that the terminal or a multiplexer discards. If your terminal cannot send these combinations, use the configurable Alt tab bindings instead. Interactive output remains trusted terminal access, including terminal-specific passthrough controls. These protections apply to local TUI handoffs (`/shell` and `!command`); RPC shell workers remain captured and noninteractive.

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
| `source <file>` | Parse and apply aliases and exports from an rc file immediately. |
| `. <file> [args...]` | Execute a native script in the current shell. |
| `unset KEY` | Remove an environment variable. |
| `alias [name]` | List, inspect, or create aliases. |
| `unalias name` / `unalias -a` | Remove aliases. |
| `capture <command>` | Run with bounded, sanitized transcript output. |
| `pty <command>` | Compatibility spelling for interactive terminal handoff. |
| `clear` | Clear the visible transcript. |
| `exit` / `logout` | Leave shell mode. |

Native aliases expand before builtin lookup. Prompt-only conveniences remain host-routed.

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

Native aliases replace unquoted command tokens at read time:

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

Native aliases may expand other aliases, with cycle detection; they are not shell functions. The separate `!command` path still performs only one command-prefix replacement. Use `alias` to list aliases, `alias name=value` to create one for subsequent complete input units, and `unalias` to remove one.

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
