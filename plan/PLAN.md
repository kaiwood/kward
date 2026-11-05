# Native kwsh POSIX.1-2024 implementation plan

## Goal

Bring standalone `kwsh` into conformance with the POSIX.1-2024 shell requirements, then complete the separately identified User Portability Utilities (UP) and XSI requirements.

This plan starts from the confirmed gaps found in the latest audit. It is not an exhaustive certification checklist yet. Passing the existing regression suite does not prove full conformance; the final audit must identify requirements that these steps have not covered.

Keep the hosted `/shell` contract separate. Reserved shutdown signals, supervised `exec`, tab-owned descendant cleanup, and sandbox boundaries must not be weakened to make the hosted runtime resemble an unrestricted standalone shell.

## Working rules

For each implementation step:

1. Read the relevant POSIX requirement and existing implementation.
2. Add focused regression tests that demonstrate the gap.
3. Make the smallest correct change without unrelated refactoring.
4. Run the focused tests and the related shell suite.
5. Review the diff for side effects, temporary diagnostics, and abandoned fixes.
6. Update user documentation, scoped shell-agent guidance, and the changelog when behavior changes. Update `AGENTS.md` when architecture or conventions change.
7. Commit the completed implementation step separately and record its verification results below.

Use POSIX as the authority. Bash and the host `/bin/sh` are useful comparison tools, not conformance oracles. Do not turn unspecified behavior into a universal test expectation. Never introduce an implicit Bash or `/bin/sh` fallback.

Do not change unrelated failing tests to obtain a green suite. Record baseline failures and establish whether a failure is caused by the current change.

## Step 1 — Establish the baseline and requirement matrix

- [x] Record the starting revision and any existing workspace changes.
- [x] Run the focused shell suite and full repository suite. Record failures and skips before implementation.
- [x] Create a requirement matrix covering the shell language, `sh` invocation, required utilities, and relevant locale rules.
- [x] For each requirement, record its POSIX reference, profile, implementation owner, test coverage, and status.
- [x] Use explicit statuses: confirmed gap, implemented and tested, not yet audited, permitted implementation choice, optional profile, or intentional hosted difference.
- [x] Track base shell, UP, and XSI milestones separately. Missing optional profiles must not be reported as base-shell failures.

Matrix: [POSIX_REQUIREMENTS.md](POSIX_REQUIREMENTS.md). Broad clauses and utility contracts remain explicitly unaudited even where partial regression coverage exists.

**Complete when:** every gap in this plan has a requirement entry, and unaudited areas are visible rather than assumed compliant.

## Step 2 — Correct shell initialization and invocation

Relevant code: `native_runtime.rb`, `native_expansion.rb`, `script_runner.rb`, and `exe/kwsh`.

- [x] Initialize `PPID` to the parent process ID at shell startup. Preserve its required value in subshell environments.
- [x] Initialize `OPTIND` to `1` on invocation rather than relying on a fallback inside `getopts`.
- [x] Preserve an inherited `PWD` when it satisfies the standard's requirements for an absolute logical pathname of the current directory. Handle invalid values according to the specified fallback rules.
- [x] Derive the default `$0` from the invocation rather than hard-coding `kwsh`. Preserve the separate rules for command files and an explicit `-c` command name.
- [x] Correct handling of a leading `-` operand, including `kwsh - script` and the applicable stdin/command-string forms.

**Regression coverage:** clean and inherited environments, valid and invalid logical `PWD`, symlinked directories, file/stdin/`-c` modes, explicit command names, positional arguments, and subshell state.

**Complete when:** startup state and operand handling match the documented POSIX rules without changing hosted workspace ownership or stdin read-ahead behavior.

## Step 3 — Complete alias contracts and execution tracing

Relevant code: `native_runtime.rb`, `native_syntax.rb`, and the alias/invocation tests.

- [ ] Accept all required alias names, including numeric names and names containing the permitted `!`, `%`, `,`, `-`, `@`, and `_` characters.
- [ ] Add regression cases such as `1`, `a%b`, `a@b`, and `a,b`. Do not require extension-only names such as names containing a dot.
- [ ] Change `alias` listing output to the specified `name=value` format with suitable quoting, without the extra `alias ` prefix.
- [ ] Keep `alias` output requirements separate from the command-description requirements of `command -v` and `type`.
- [ ] Make `set -x` trace assignment-only commands, not just commands with a non-empty argument vector.
- [ ] Check tracing order against expansion, execution, and stderr redirection.

**Regression coverage:** alias definition, lookup, listing, quoting, substitution, recursion protection, and assignment-only tracing. Preserve shared-stream quote and here-document handling.

**Complete when:** the required alias name set and output format work, and every required command category receives an execution trace.

## Step 4 — Complete `umask` and `cd` option semantics

Relevant code: `native_builtins.rb` and `native_runtime.rb`.

- [ ] Implement the applicable symbolic-mode grammar for `umask`, including permission-copy forms such as `g=u` and supported combinations of symbolic operations.
- [ ] Accept required option forms, including `umask -- 022` and `umask -S 022`.
- [ ] Preserve the rule that setting a mask does not print the query output merely because `-S` was supplied.
- [ ] Verify numeric and symbolic mask round trips and effects on subsequently created files.
- [ ] Add POSIX.1-2024 `cd -P -e` support, including the required failure status when the directory changes successfully but its pathname cannot be determined.
- [ ] Preserve last-option-wins behavior for `-L` and `-P` and the existing `CDPATH` behavior.

**Regression coverage:** permission copying, option terminators, symbolic operations, file creation, subshell isolation, and physical-directory reporting failures. Use controlled fixtures for permission-sensitive tests and explicitly report environmental skips.

**Complete when:** the documented utility grammar and option combinations work without leaking process-global umask changes into the host.

## Step 5 — Preserve current-directory identity

Relevant code: directory state in `native_runtime.rb` and process execution in `native_process.rb`.

- [ ] Fix logical `cd` normalization so `cd missing/..` fails instead of removing the missing component and succeeding.
- [ ] Check preceding components before eliminating `..`, including non-directories and symbolic links.
- [ ] Stop relying only on a pathname to represent the active directory. Preserve directory identity across renames and handle removal according to the underlying filesystem semantics.
- [ ] Keep logical `PWD` presentation distinct from the mechanism used to retain the actual current directory.
- [ ] Ensure external commands, subshells, sourcing, relative redirections, and relative pathname expansion use the correct directory after a rename.
- [ ] Give any retained directory handles explicit ownership and cleanup. Do not change Kward's process-global working directory as a shortcut.

**Key regression:** enter a directory, rename it through a child command, then execute another command successfully from the same directory.

**Complete when:** logical traversal obeys POSIX and renaming the current directory no longer breaks subsequent execution. Hosted workspace isolation must remain intact.

## Step 6 — Support inherited standalone file descriptors

Relevant code: `script_runner.rb`, `native_runtime.rb`, `native_process.rb`, and descriptor lifecycle helpers.

- [ ] Make descriptors inherited by standalone kwsh available to shell redirections within the supported descriptor range.
- [ ] Add a parent-process fixture that supplies an open descriptor 3, then verify `cat <&3` can read it.
- [ ] Cover writable inherited descriptors, duplication, closing, persistence through `exec`, and propagation into children and native executable-text fallback.
- [ ] Distinguish user-inherited descriptors from Ruby/Kward private descriptors. Do not expose host protocol sockets or other internal resources.
- [ ] Verify descriptor ownership and close-on-exec behavior, including failure paths.

**Complete when:** inherited descriptors 0–9 behave correctly without exposing private host descriptors or leaking handles.

Supporting descriptors above 9 is not a prerequisite: POSIX permits an implementation-defined maximum of at least 9.

## Step 7 — Correct signal and trap semantics

Relevant code: `native_traps.rb`, `native_jobs.rb`, `script_runner.rb`, and process/substitution lifecycle code.

- [ ] Initialize the required interactive signal dispositions: ignore `SIGTERM` and `SIGQUIT` by default, and implement the required monitor-mode handling of `SIGTTIN`, `SIGTTOU`, and `SIGTSTP`.
- [ ] Verify `SIGINT` handling at the prompt and during command execution.
- [ ] Preserve the rule that signals ignored on entry to a non-interactive shell cannot be trapped or reset by that shell.
- [ ] Make `trap -p` report all required conditions, including default dispositions. Explicit requests such as `trap -p INT` must produce restorable output.
- [ ] Include inherited ignored signals where required in trap listings.
- [ ] Preserve trap inspection/save-and-restore behavior across subshells and command substitutions, even when execution dispositions are reset on entry to the subshell.
- [ ] Test restoration through `saved=$(trap -p)` followed by `eval "$saved"`.
- [ ] Keep the hosted shutdown signal reservation and descendant ownership rules unchanged.

**Regression coverage:** isolated subprocess tests for inherited dispositions, default and explicit traps, trap inspection, EXIT status, deferred handlers, job-control signals, and cancellation. Bound all waits and clean up every child; do not risk leaving stopped or orphaned processes.

**Complete when:** signal defaults, trap mutation restrictions, and trap round trips satisfy the selected requirements on macOS and Linux.

## Step 8 — Recover from failed interactive `exec`

Relevant code: `native_builtins.rb`, `native_process.rb`, and standalone interactive execution.

- [ ] Prevent a missing executable from terminating an interactive shell.
- [ ] Test both PATH lookup failure and an explicit missing pathname; also audit found-but-unexecutable files and other execution failures.
- [ ] Ensure recovery leaves the interpreter's descriptors and directory state usable. Merely removing an exit instruction is not sufficient if replacement preparation has already mutated process state.
- [ ] Verify the user can submit a fresh command after the failure. Do not require continuation of an abandoned input submission where the standard permits recovery at the next submission.
- [ ] Preserve true process replacement on successful standalone `exec`, including PID behavior and native ENOEXEC fallback.
- [ ] Keep hosted supervised execution and shutdown behavior explicit and separately tested.

**Complete when:** failed interactive execution recovers safely, successful standalone replacement still replaces the process, and non-interactive error consequences remain correct.

## Step 9 — Resolve nonstandard resource limits

Relevant code: arithmetic, parser, alias, substitution, pattern, glob, and job limits.

- [ ] Inventory every explicit size, depth, count, and work limit.
- [ ] Classify each limit against the standard: permitted implementation limit, underlying system constraint, or additional product safety policy.
- [ ] Add a regression for an otherwise valid arithmetic expression exceeding 4,096 bytes without overflowing an integer, such as `1` followed by many `+ 0` terms.
- [ ] Remove or redesign artificial restrictions that contradict standalone conformance requirements. Do not replace them with unsafe evaluation or recursive wildcard matching.
- [ ] Separate hosted safety quotas from standalone behavior where needed, or explicitly document the remaining nonconformance.
- [ ] Retain necessary host capture bounds, cancellation, resource ownership, and sandbox protections.
- [ ] Document supported arithmetic precision and other implementation-defined choices accurately; exact Bash integer behavior is not the target.

**Complete when:** every limit has an explicit standards justification or a clearly identified non-conforming mode/policy. Do not remove all safeguards indiscriminately.

## Step 10 — Complete the User Portability Utilities profile

Treat this as a separate milestone after core correctness. Divide it into small, independently tested commits.

- [ ] Implement the command-history model and `fc`, including `HISTFILE`, `HISTSIZE`, and `FCEDIT` behavior.
- [ ] Implement the required vi command-line editing behavior and `set -o vi`.
- [ ] Implement `set -o ignoreeof`.
- [ ] Accept `set -o nolog`; the obsolete option may have no effect where the standard permits that.
- [ ] Implement PS1 exclamation-mark/history-number expansion, including `!` and `!!`.
- [ ] Parameter-expand `PS4` for execution traces rather than hard-coding `+ `.
- [ ] Implement mail notification behavior controlled by `MAIL`, `MAILPATH`, and `MAILCHECK`.
- [ ] Preserve existing guarded `ENV` startup and parameter-expanded prompt behavior.
- [ ] Define private storage and cleanup rules for history and edited history files, and test cancellation and editor failures.

**Complete when:** the UP entries in the requirement matrix are implemented and tested, or the project explicitly declines that optional profile without claiming it is complete.

Emacs editing and command substitution in prompt strings are not required for this milestone.

## Step 11 — Complete the XSI shell requirement for `ulimit`

- [ ] Implement standardized `ulimit` file-size-limit query and setting behavior, including its required options, units, and error handling.
- [ ] Apply limits to the appropriate shell execution environment and its descendants without changing unrelated Kward processes.
- [ ] Test subshell isolation, inheritance, supported limit changes, and failures using small disposable files and isolated processes.
- [ ] Audit the requirement matrix for any other applicable XSI shell requirements before declaring the profile complete.

**Complete when:** standardized `ulimit` behavior and the applicable XSI requirements are verified. Bash's broader collection of resource-limit options is not automatically part of this scope.

## Step 12 — Perform the final conformance audit

- [ ] Audit every required builtin's options, operands, output, status, and error consequences.
- [ ] Audit quoting, token recognition, expansion order, field splitting, declaration utilities, and redirection interactions.
- [ ] Audit signals, traps, asynchronous jobs, pipelines, stopped jobs, and `wait` interactions.
- [ ] Audit permissions, symlinks, renamed/deleted directories, descriptor inheritance, and relevant filesystem races.
- [ ] Test supported locales and encodings on macOS and Linux. Distinguish deterministic matcher coverage from tests requiring installed locale data.
- [ ] Check every implementation-defined choice has documentation and coverage where practical.
- [ ] Use independent conformance tests where available, reviewing their assumptions against POSIX.1-2024 before adopting expectations.
- [ ] Turn newly discovered gaps into additional implementation steps. Do not close the plan merely because the original gap list is exhausted.
- [ ] Run the focused and full suites, review skips and baseline failures, and verify there are no unrelated changes.
- [ ] Publish an accurate support statement distinguishing base shell behavior, optional profiles, hosted exceptions, and remaining limitations.

**Complete when:** no required item in the claimed scope remains a known gap or an unaudited assumption. Formal certification, if desired, is a separate process from completing this engineering checklist.

## Verification commands

Focused shell suite:

```sh
ruby -Itest -e '(Dir["test/test_native_shell*.rb"] + %w[test/test_persistent_shell_session.rb test/test_kwsh.rb test/test_shell_prompt.rb]).sort.each { |file| require_relative file }'
```

Full repository suite:

```sh
ruby -Itest -e 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
```

Diff hygiene:

```sh
git diff --check
git status --short
```

Record each completed step's commit, test commands/results, platform, and any justified skips or remaining issues here. Do not reuse old test counts as evidence for a later revision.

### Step 1 verification — baseline and matrix

- Starting revision: `44b8ba13a7cc33bdbf3daadf0e0713e2607bdf8b`; `git status --short` was empty (no tracked changes). `/plan/` is ignored by `.gitignore:37`; the supplied `PLAN.md`, `editor.md`, `TODO.md`, and `WORKERS.md` existed there. Only this plan and its new requirement matrix are explicitly added for the requested per-step commit history; the ignore rule and other planning files remain untouched.
- Platform: Darwin arm64; Ruby 4.0.3 (2026-04-21, revision 85ddef263a), arm64-darwin25. Linux was not tested.
- Focused shell command above, seed 13641: **284 runs, 1,793 assertions, 0 failures, 0 errors, 0 skips**.
- Full repository command above, seed 20912: **2,550 runs, 13,212 assertions, 1 failure, 0 errors, 2 skips**.
- Existing failure: `TestEditorPrompt#test_editor_stays_visible_and_shows_spinner_while_agent_runs`, `test/test_editor_prompt.rb:109`; expected spinner text `· ·`, received `⠋`. No shell implementation had been changed. Leave this unrelated test/code untouched.
- Skip detail confirmed with `ruby -Itest test/sandbox/test_linux_bubblewrap_runner.rb --verbose`: `test_denied_child_network_cannot_connect_to_loopback` and `test_workspace_write_enforces_filesystem_boundary` are disabled unless `KWARD_RUN_BUBBLEWRAP_TESTS=1` (also require Linux). Follow-up: 5 runs, 16 assertions, 0 failures/errors, 2 skips.
- All planned gaps now have matrix entries; Base, UP, XSI and intentional hosted differences are separated. Final exhaustive auditing remains step 12.
- Implementation-step commit: `23d0aad` — `docs(shell): record POSIX baseline and requirement matrix`. Documentation-only changes; `git diff --check` passed.

### Step 2 verification — initialization and invocation

- Implementation-step commit: `fix(shell): correct POSIX initialization and invocation` (the separate commit containing this record; parent `23d0aad`). Platform remains Darwin arm64, Ruby 4.0.3; Linux verification remains outstanding.
- Read POSIX.1-2024 SCL 2.5.2–2.5.3, `sh` OPTIONS/OPERANDS/STDIN, and `getopts` DESCRIPTION (primary links below and in the matrix). Preserve resolvable valid inherited logical paths even beyond PATH_MAX (a permitted choice); physical-path permission failures have an unspecified PWD. Tests do not turn undefined `-` plus `--` combinations into requirements.
- Added nine invocation regressions. Before implementation, `ruby -Itest test/test_native_shell_invocation.rb`: **22 runs, 146 assertions, 6 failures, 1 error, 0 skips**, demonstrating absent startup variables, discarded logical PWD, hard-coded `$0`, and incorrect `- script` selection.
- After implementation, the same invocation command, seed 11845: **22 runs, 208 assertions, 0 failures, 0 errors, 0 skips**.
- Final focused shell command above, seed 41581: **293 runs, 1,917 assertions, 0 failures, 0 errors, 0 skips**. Includes prompt guidance, hosted-root isolation, subshell state, native executable-text fallback and stdin handoff coverage.
- Final full repository command above, seed 1132: **2,559 runs, 13,336 assertions, 1 failure, 0 errors, 2 skips**. The same existing editor-spinner failure at `test/test_editor_prompt.rb:109` and disabled Bubblewrap integration skips remain; no unrelated code/tests were changed.
- One existing native-fallback test expectation now uses `File.realpath(@directory)`: startup without inherited PWD must select the physical pathname, so macOS `/var/...` becomes `/private/var/...`. The assertion still verifies that the child did not change its parent's directory.
- Updated user docs, shell-agent guidance, changelog, agent conventions and matrix INIT-1 through INIT-5. No new frontend API: persistent shell support remains explicitly TUI-only; standalone kwsh is still an ordinary sandboxed external program for RPC/Pan tools.
- Reviewed the diff and ran `git diff --check`; no debug artifacts, shell fallback, host-directory mutation or unrelated cleanup. The remaining plan steps and unaudited matrix rows stay open.

## Not required for POSIX shell conformance

Do not expand this plan merely to add Bash arrays, `[[ … ]]`, regex matching, `wait -n`, DEBUG/ERR/RETURN traps, emacs editing, descriptors above 9, or `eval --`. Additional prompt command substitution is also not required. Preserve existing extensions where they do not conflict with required behavior.

## Primary references

- [POSIX.1-2024 Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html)
- [`sh` invocation, environment, signals, and UP behavior](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html)
- [`cd`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cd.html)
- [`getopts`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/getopts.html)
- [`alias`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/alias.html) and [Alias Name definition](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap03.html#tag_03_10)
- [`umask`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/umask.html) and [`chmod` symbolic modes](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html)
- [`fc`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fc.html)
- [`ulimit`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ulimit.html)
