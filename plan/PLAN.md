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

- [x] Accept all required alias names, including numeric names and names containing the permitted `!`, `%`, `,`, `-`, `@`, and `_` characters.
- [x] Add regression cases such as `1`, `a%b`, `a@b`, and `a,b`. Do not require extension-only names such as names containing a dot.
- [x] Change `alias` listing output to the specified `name=value` format with suitable quoting, without the extra `alias ` prefix.
- [x] Keep `alias` output requirements separate from the command-description requirements of `command -v` and `type`.
- [x] Make `set -x` trace assignment-only commands, not just commands with a non-empty argument vector.
- [x] Check tracing order against expansion, execution, and stderr redirection.

**Regression coverage:** alias definition, lookup, listing, quoting, substitution, recursion protection, and assignment-only tracing. Preserve shared-stream quote and here-document handling.

**Complete when:** the required alias name set and output format work, and every required command category receives an execution trace.

## Step 4 — Complete `umask` and `cd` option semantics

Relevant code: `native_builtins.rb` and `native_runtime.rb`.

- [x] Implement the applicable symbolic-mode grammar for `umask`, including permission-copy forms such as `g=u` and supported combinations of symbolic operations.
- [x] Accept required option forms, including `umask -- 022` and `umask -S 022`.
- [x] Preserve the rule that setting a mask does not print the query output merely because `-S` was supplied.
- [x] Verify numeric and symbolic mask round trips and effects on subsequently created files.
- [x] Add POSIX.1-2024 `cd -P -e` support, including the required failure status when the directory changes successfully but its pathname cannot be determined.
- [x] Preserve last-option-wins behavior for `-L` and `-P` and the existing `CDPATH` behavior.

**Regression coverage:** permission copying, option terminators, symbolic operations, file creation, subshell isolation, and physical-directory reporting failures. Use controlled fixtures for permission-sensitive tests and explicitly report environmental skips.

**Complete when:** the documented utility grammar and option combinations work without leaking process-global umask changes into the host.

## Step 5 — Preserve current-directory identity

Relevant code: directory state in `native_runtime.rb` and process execution in `native_process.rb`.

- [x] Fix logical `cd` normalization so `cd missing/..` fails instead of removing the missing component and succeeding.
- [x] Check preceding components before eliminating `..`, including non-directories and symbolic links.
- [x] Stop relying only on a pathname to represent the active directory. Preserve directory identity across renames and handle removal according to the underlying filesystem semantics.
- [x] Keep logical `PWD` presentation distinct from the mechanism used to retain the actual current directory.
- [x] Ensure external commands, subshells, sourcing, relative redirections, and relative pathname expansion use the correct directory after a rename.
- [x] Give any retained directory handles explicit ownership and cleanup. Do not change Kward's process-global working directory as a shortcut.

**Key regression:** enter a directory, rename it through a child command, then execute another command successfully from the same directory.

**Complete when:** logical traversal obeys POSIX and renaming the current directory no longer breaks subsequent execution. Hosted workspace isolation must remain intact.

## Step 6 — Support inherited standalone file descriptors

Relevant code: `script_runner.rb`, `native_runtime.rb`, `native_process.rb`, and descriptor lifecycle helpers.

- [x] Make descriptors inherited by standalone kwsh available to shell redirections within the supported descriptor range.
- [x] Add a parent-process fixture that supplies an open descriptor 3, then verify `cat <&3` can read it.
- [x] Cover writable inherited descriptors, duplication, closing, persistence through `exec`, and propagation into children and native executable-text fallback.
- [x] Distinguish user-inherited descriptors from Ruby/Kward private descriptors. Do not expose host protocol sockets or other internal resources.
- [x] Verify descriptor ownership and close-on-exec behavior, including failure paths.

**Complete when:** inherited descriptors 0–9 behave correctly without exposing private host descriptors or leaking handles.

Supporting descriptors above 9 is not a prerequisite: POSIX permits an implementation-defined maximum of at least 9.

## Step 7 — Correct signal and trap semantics

Relevant code: `native_traps.rb`, `native_jobs.rb`, `script_runner.rb`, and process/substitution lifecycle code.

- [x] Initialize the required interactive signal dispositions: ignore `SIGTERM` and `SIGQUIT` by default, and implement the required monitor-mode handling of `SIGTTIN`, `SIGTTOU`, and `SIGTSTP`.
- [x] Verify `SIGINT` handling at the prompt and during command execution.
- [x] Preserve the rule that signals ignored on entry to a non-interactive shell cannot be trapped or reset by that shell.
- [x] Make `trap -p` report all required conditions, including default dispositions. Explicit requests such as `trap -p INT` must produce restorable output.
- [x] Include inherited ignored signals where required in trap listings.
- [x] Preserve trap inspection/save-and-restore behavior across subshells and command substitutions, even when execution dispositions are reset on entry to the subshell.
- [x] Test restoration through `saved=$(trap -p)` followed by `eval "$saved"`.
- [x] Keep the hosted shutdown signal reservation and descendant ownership rules unchanged.

**Regression coverage:** isolated subprocess tests for inherited dispositions, default and explicit traps, trap inspection, EXIT status, deferred handlers, job-control signals, and cancellation. Bound all waits and clean up every child; do not risk leaving stopped or orphaned processes.

- [ ] Verify the selected signal/trap regressions on Linux (local Docker daemon unavailable).

**Implementation note:** macOS regressions cover the changes below, but the cross-platform completion gate remains open. Ruby-reserved `ILL`, `FPE`, `BUS`, `SEGV`, and `VTALRM` actions remain unsupported; their default dispositions can be listed/restored. This step does not close the full trap utility audit.

**Complete when:** signal defaults, trap mutation restrictions, and trap round trips satisfy the selected requirements on macOS and Linux.

## Step 8 — Recover from failed interactive `exec`

Relevant code: `native_builtins.rb`, `native_process.rb`, and standalone interactive execution.

- [x] Prevent a missing executable from terminating an interactive shell.
- [x] Test both PATH lookup failure and an explicit missing pathname; also audit found-but-unexecutable files and other execution failures.
- [x] Ensure recovery leaves the interpreter's descriptors, directory state, and signal dispositions usable. Merely removing an exit instruction is not sufficient if replacement preparation has already mutated process state.
- [x] Verify the user can submit a fresh command after the failure. Do not require continuation of an abandoned input submission where the standard permits recovery at the next submission.
- [x] Preserve true process replacement on successful standalone `exec`, including PID behavior and native ENOEXEC fallback.
- [x] Keep hosted supervised execution and shutdown behavior explicit and separately tested.

**Complete when:** failed interactive execution recovers safely, successful standalone replacement still replaces the process, and non-interactive error consequences remain correct.

## Step 9 — Resolve nonstandard resource limits

Relevant code: arithmetic, parser, alias, substitution, pattern, glob, and job limits.

- [x] Inventory every explicit size, depth, count, and work limit.
- [x] Classify each limit against the standard: permitted implementation limit, underlying system constraint, or additional product safety policy.
- [x] Add a regression for an otherwise valid arithmetic expression exceeding 4,096 bytes without overflowing an integer, such as `1` followed by many `+ 0` terms.
- [x] Remove or redesign artificial restrictions that contradict standalone conformance requirements. Do not replace them with unsafe evaluation or recursive wildcard matching.
- [x] Separate hosted safety quotas from standalone behavior where needed, or explicitly document the remaining nonconformance.
- [x] Retain necessary host capture bounds, cancellation, resource ownership, and sandbox protections.
- [x] Document supported arithmetic precision and other implementation-defined choices accurately; exact Bash integer behavior is not the target.

**Disposition:** the arithmetic expression-byte and flat-chain recursion restrictions are removed. The remaining quotas are retained and explicitly classified in `doc/shell.md` under Resource limits and conformance. This completes the inventory/policy-disclosure milestone, not standalone resource-limit conformance; there is no unrestricted mode.

**Complete when:** every limit has an explicit standards justification or a clearly identified non-conforming mode/policy. Do not remove all safeguards indiscriminately.

## Step 10 — Complete the User Portability Utilities profile

Treat this as a separate milestone after core correctness. Divide it into small, independently tested commits.

- [x] Implement the command-history model and `fc`, including `HISTFILE`, `HISTSIZE`, and `FCEDIT` behavior.
- [x] Implement the required vi command-line editing behavior and `set -o vi`.
- [x] Implement `set -o ignoreeof`.
- [x] Accept `set -o nolog`; the obsolete option may have no effect where the standard permits that.
- [x] Implement PS1 exclamation-mark/history-number expansion, including `!` and `!!`.
- [x] Parameter-expand `PS4` for execution traces rather than hard-coding `+ `.
- [x] Implement mail notification behavior controlled by `MAIL`, `MAILPATH`, and `MAILCHECK`.
- [x] Preserve existing guarded `ENV` startup and parameter-expanded prompt behavior.
- [x] Define private storage and cleanup rules for history and edited history files, and test cancellation and editor failures.

- [ ] Close the UP profile gate: verify Linux and resolve/review retained vi macro depth/byte policies before claiming profile conformance.

**Implementation status:** requested functionality is implemented and tested on macOS; the optional profile is not yet declared complete. `type` was reclassified as XSI after checking its Issue 8 shading.

**Complete when:** the UP entries in the requirement matrix are implemented and tested, or the project explicitly declines that optional profile without claiming it is complete.

Emacs editing and command substitution in prompt strings are not required for this milestone.

## Step 11 — Implement standardized `ulimit` and audit XSI shell requirements

**Issue 8 correction:** the original file-size-only/XSI description was outdated. POSIX.1-2024 moved `ulimit` into Base except for `-t` (CPU time), and requires `-H`, `-S`, `-a`, `-c`, `-d`, `-f`, `-n`, `-s`, and `-v`. These are standardized options, not Bash-only scope expansion.

- [x] Implement standardized resource-limit query and setting behavior, including soft/hard selection, units, numeric/unlimited values, and error handling.
- [x] Apply limits to the appropriate shell execution environment and its descendants without changing unrelated Kward processes.
- [x] Test subshell isolation, inheritance, supported limit changes, and failures using small disposable files and isolated processes.
- [x] Audit XSI shading in the shell language, sh, and relevant utility pages; expand the requirement matrix instead of assuming `ulimit` completes the profile.
- [ ] Close the XSI profile gate: resolve the confirmed echo/message-catalog gaps, complete the remaining utility/locale audits, and verify Linux.

**Implementation status:** resource-limit behavior is implemented and tested on macOS. The audit also added type operand validation and case-independent kill signal names, with regressions for these and numeric trap/kill forms. XSI is not declared complete; newly identified requirements remain visible in XSI-2 through XSI-6.

**Complete when:** standardized `ulimit` behavior and the applicable XSI requirements are verified. Bash's additional resource-limit options are not automatically part of this scope.

## Step 12 — Perform the final conformance audit

- [ ] Audit every required builtin's options, operands, output, status, and error consequences.
- [ ] Audit quoting, token recognition, expansion order, field splitting, declaration utilities, and redirection interactions.
- [ ] Audit signals, traps, asynchronous jobs, pipelines, stopped jobs, and `wait` interactions.
- [ ] Audit permissions, symlinks, renamed/deleted directories, descriptor inheritance, and relevant filesystem races.
- [ ] Test supported locales and encodings on macOS and Linux. Distinguish deterministic matcher coverage from tests requiring installed locale data.
- [ ] Check every implementation-defined choice has documentation and coverage where practical.
- [ ] Use independent conformance tests where available, reviewing their assumptions against POSIX.1-2024 before adopting expectations.
- [x] Turn newly discovered gaps into additional implementation steps. Do not close the plan merely because the original gap list is exhausted. Audit found and fixed missing `PS2` continuation prompting for interactive `read`; tracked in `UTIL-6` and covered by `test_native_shell_interactive.rb`.
- [ ] Run the focused and full suites, review skips and baseline failures, and verify there are no unrelated changes.
- [ ] Publish an accurate support statement distinguishing base shell behavior, optional profiles, hosted exceptions, and remaining limitations.

**Complete when:** no required item in the claimed scope remains a known gap or an unaudited assumption. Formal certification, if desired, is a separate process from completing this engineering checklist.

### Step 12 audit record — in progress

- Read POSIX.1-2024 `read` DESCRIPTION/STDERR: a backslash-newline continuation on a terminal in an interactive shell must prompt using `PS2`. The native `read` implementation consumed the continuation without prompting. Added a PTY regression that failed before the fix, then implemented parameter-expanded `PS2` output to stderr for interactive terminal input. This closes only that narrow item; `UTIL-6` remains unaudited.
- Read POSIX.1-2024 `getopts`: non-silent option errors must identify the invoking program (`$0`). Native diagnostics named only `getopts`; added failing coverage for unknown options and missing option arguments, then included the runtime shell name in both diagnostics. Remaining `getopts`/`read` contracts keep `UTIL-6` open.
- Read POSIX.1-2024 `.`: when searching `PATH`, the shell must find a readable file, not stop at the first matching but unreadable file. Added a deterministic permission regression (mode 000; verified as non-root), which failed before the fix. Native dot-sourcing now tries candidates in order and skips open failures caused by inaccessible or vanished paths. `UTIL-1` remains unaudited.
- Audited the `shift` positional-parameter behavior in POSIX.1-2024 SCL 2.15: a zero count leaves parameters unchanged; a count equal to the parameter count succeeds and empties the list; a count larger than the list returns non-zero without modifying it. Added regression coverage for these boundaries. Broader `UTIL-1` contracts remain unaudited.
- Audited `return` status selection in POSIX.1-2024 SCL 2.15: with no operand it returns the status of the last command executed in the function; an explicit valid status is returned from the function. Added direct regression coverage for both cases. `return` outside a function or dot-script, argument validation, and broader `UTIL-1` contracts remain open.
- Audited the nested-loop case for POSIX.1-2024 `continue`: `continue 2` resumes the second enclosing loop, bypassing the remainder of the inner and outer loop bodies. Added a regression. The broader `break`/`continue` operand/error contracts and `UTIL-1` remain open. Authorities: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/break.html and https://pubs.opengroup.org/onlinepubs/9799919799/utilities/continue.html.
- Authorities: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/read.html, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/getopts.html, and https://pubs.opengroup.org/onlinepubs/9799919799/utilities/dot.html .
- Focused shell suite after the `read` change: **404 runs, 2,947 assertions, 0 failures/errors/skips** (seed 16692). After the `getopts` diagnostic change: **405 runs, 2,957 assertions, 0 failures/errors/skips** (seed 57109); focused `getopts` tests passed (3 runs, 26 assertions, seed 47461). After the dot PATH-search fix, related suites passed: **158 runs, 1,172 assertions, 0 failures/errors/skips** (seed 62298); this included native core, directory, runner, and POSIX requirement tests.
- Full repository suite, run after the `read` change and before the `getopts` diagnostic adjustment: **2,670 runs, 14,369 assertions, 1 failure, 0 errors, 2 skips** (seed 27346). The known editor spinner failure remains (`test/test_editor_prompt.rb:109`, expected `· ·`, rendered `⠋`); Bubblewrap integration tests remain disabled by their existing environment gate. No unrelated changes were made.
- Audit is not complete: matrix rows remain unaudited; documented quota-policy nonconformance, Ruby-reserved trap limitations, XSI message-catalog/echo gaps, and missing Linux verification remain open. Do not claim Base, UP, or XSI conformance.

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

## Step 3 verification — aliases and tracing

- Commit: `5cda44c` — `fix(shell): complete alias names and assignment tracing` (parent `e91fedd0`). Darwin arm64, Ruby 4.0.3; Linux not run.
- References: POSIX alias STDOUT, XBD 3.10, and SCL set `-x` (links above/in matrix). Required names, listing/lookup quoting and restoration, and command-description separation covered. Existing shared-lexer/recursion tests remain unchanged.
- New focused cases failed before implementation: 3 runs, 10 assertions, 3 failures. After implementation the focused shell command above (seed 31927) passed: **296 runs, 1,980 assertions, 0 failures/errors/skips**.
- Assignment expansions execute once in order, tracing before assignment/dispatch; stderr redirections retain existing trace routing. Redirection-only commands also trace. UP PS4 expansion remains step 10.
- Documentation and scoped shell guidance updated; no frontend capability changes. `git diff --check` passed. Full suite deferred to the end of steps 3–5; the step 1/2 editor-spinner baseline failure remains recorded above.

## Step 4 verification — umask and cd options

- Commit: `0a7c06c` — `fix(shell): complete umask modes and cd physical reporting` (parent `5cda44c`). Darwin arm64, Ruby 4.0.3; Linux not run.
- Read POSIX umask OPTIONS/OPERANDS/STDOUT, chmod symbolic grammar, and cd algorithm/options/status. Added `test_native_shell_utilities.rb`: before implementation, **5 runs, 33 assertions, 4 failures**; invalid-input atomicity already passed.
- Final focused shell command above, seed 45126: **301 runs, 2,087 assertions, 0 failures/errors/skips**. Covers copy/compound/empty symbolic operations, query/set distinction, round trips, subshell file modes, invalid masks, physical/logical option precedence and CDPATH regressions.
- Path-reporting denial is injected deterministically after validating a real target directory, including a subsequent write proving the change persisted. This avoids root/filesystem-dependent permission skips; no environmental skips were needed. The directory-handle implementation in step 5 must preserve this distinction.
- Non-permission symbolic s/t bits are ignored (POSIX leaves their umask interpretation unspecified); X consults original allowed execute bits. Host umask isolation tests still pass.
- Docs, scoped guidance and matrix updated. `git diff --check` passed. Full suite will run after step 5; no unrelated baseline failure was modified.

## Step 5 verification — directory identity

- Commit: `fix(shell): retain current directory identity across renames` (separate step commit containing this record; parent `0a7c06c`). Darwin arm64, Ruby 4.0.3. Linux was not run: Docker is installed but its daemon/socket is unavailable; no images were downloaded or services started.
- Used POSIX cd steps 7–10, pwd logical/physical behavior and SCL execution-environment requirements. Directory mechanics live in `native_directory.rb`: search-only openat handles, owned copies/cleanup, relative file opening, kernel physical-name discovery and exec-bound fchdir. No agent-host process-global chdir; no shell fallback. Linux name discovery requires mounted procfs (documented), while Darwin uses the kernel F_GETPATH/MAXPATHLEN contract.
- Initial new directory regressions before implementation: **6 runs, 7 assertions, 6 failures**, covering missing/invalid components, rename/replacement, relative execution, relative redirection, deleted directories and host isolation.
- Final focused shell command above, seed 17371: **311 runs, 2,175 assertions, 0 failures, 0 errors, 0 skips**. The ten new directory tests cover subshells, native source/scripts, relative PATH cache invalidation even when the old pathname is replaced, globs, physical parent navigation after removal, actual search-only permissions, descriptor closure/copying/close-on-exec, descriptor-remapping failure, and unchanged host cwd. The step 4 injected physical-reporting-failure regression still verifies a successful subsequent relative write; it was strengthened to check that `pwd -L` does not print a dot-containing fallback after that reporting failure.
- Full repository command above, seed 1407: **2,577 runs, 13,594 assertions, 1 failure, 0 errors, 2 skips**. Only the same baseline editor-spinner failure (`test/test_editor_prompt.rb:109`, expected `· ·`, rendered `⠋`) remains. The two disabled Bubblewrap integration skips remain; the new permission-sensitive directory test did not skip on this host.
- Preserved existing cd error text. Added explicit closure to prior invocation fixtures now owning directory handles. Removed the new mutable-literal warning; no debug artifacts or failed-hypothesis leftovers remain. `git diff --check` passed.
- Updated docs, changelog, scoped prompt/tests, AGENTS and matrix CD-2/CWD-1. Frontend support remains unchanged: persistent shell TUI-only, standalone executable available through existing CLI/RPC/Pan external-command paths. Broader race/permission/locale auditing and the remaining steps remain open; these passing regressions are not certification.

## Step 6 verification — inherited descriptors

- Added `test/test_native_shell_descriptors.rb`: parent-supplied input/output descriptors 3–9, shared offsets, exec duplication/closing, native scripts and ENOEXEC propagation, explicit ownership and startup-error cleanup, and private-handle exclusion. Initial regressions: 5 runs, 8 assertions, 4 failures.
- Focused descriptor suite: 8 runs, 61 assertions, no failures/errors/skips (seed 62750).
- Related shell suite: 319 runs, 2,236 assertions, no failures/errors/skips (seed 53747); prompt assertions were added afterward and verified separately.
- Standalone discovery excludes CLOEXEC handles; embedded callers retain explicit borrowed maps. Runner resource cleanup is separate from hosted descendant cleanup. Verification is on macOS arm64; Linux remains unverified.
- Authority: POSIX.1-2024 SCL 2.7 and 2.13, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html .

## Step 7 verification — signal defaults and trap round trips

- Added `test/test_native_shell_signals.rb` with isolated, time-bounded subprocess fixtures. Initial seven regressions produced six failures (seed 4776). Final focused run: **18 runs, 64 assertions, no failures/errors/skips**, seed 65379.
- Covered interactive TERM/QUIT and monitor stop-signal defaults; INT at an incomplete prompt, sent only to the shell during a command, and delivered to a foreground child; inherited ignored dispositions and interactive overrides; explicit/default trap listings; nested subshell inspection and execution reset; save/restore; EXIT status; asynchronous INT/QUIT inheritance; exec/native-script/ENOEXEC defaults; and hosted round trips without changing worker handlers or exposing USR2.
- Strengthened the existing interrupted-wait regression to assert the status observed by the trap. It initially reported 0 rather than 128 + signal. Actions now run after recording wait's status and before errexit; a separate regression covers that ordering.
- Inherited-ignore discovery uses read-only sigaction, not temporary changes to host dispositions. Interactive handlers remain scoped across startup and execution. Trap inspection snapshots preserve the originating hosted shutdown reservation. Unchanged default resets do not replace host handlers.
- Related shell suite: **337 runs, 2,310 assertions, no failures/errors/skips**, seed 27540, `/tmp/kward-step7-shell-final.log`.
- Full repository suite: **2,603 runs, 13,729 assertions, 1 failure, 0 errors, 2 skips**, seed 64485, `/tmp/kward-step7-full.log`. The sole failure is the pre-existing editor spinner assertion at `test/test_editor_prompt.rb:109` (expected `· ·`, rendered `⠋`); the existing Bubblewrap integration tests remain disabled. No unrelated tests were changed.
- `git diff --check` passed. Verified with Ruby 4.0.3 on macOS arm64. Linux verification remains **open**: the installed Docker client cannot connect to its daemon; no daemon was started or images downloaded. Ruby-reserved ILL/FPE/BUS/SEGV/VTALRM actions remain an explicit limitation (SIG-5), not a closed conformance requirement.
- Step 6 implementation commit: `b4bddbc` (`fix(shell): support inherited standalone descriptors`). Step 7 is committed separately after this verification record.
- Authorities: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html (ASYNCHRONOUS EVENTS), https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_29 (trap and SCL 2.12/2.13), and Ruby's reserved-signal implementation at https://github.com/ruby/ruby/blob/37003e92e8e59dca22c8f71fff101109192b82a9/signal.c#L1359-L1383 .

## Step 8 verification — failed interactive exec

- Added isolated, bounded subprocess regressions in `test/test_native_shell_exec.rb`: missing PATH and explicit paths, denied files, binary rejection, directories and long names; repeated failures, persistent stdin/stdout/stderr redirection, closed stderr, hidden reservation handles, signals/cwd/mask/FD flags, backup cleanup, and same-PID successful replacement. Initial suite: 3 runs, 16 assertions, 2 failures.
- POSIX exec explicitly requires successfully made redirections to remain after a failure that does not exit. Recovery restores process-internal state, not the user's successful redirections. Fresh submissions are tested; continuation of the failed submission is not required.
- A regression exposed Ruby timer-thread descriptor corruption when low descriptors were closed during a failed replacement. Standalone startup now performs a same-PID trusted-Ruby bootstrap with 3–9 reserved, moves inherited user IOs to private CLOEXEC handles, and keeps reservation handles out of the shell map. Hosted startup is unchanged. User programs still use direct execve and native-only ENOEXEC fallback.
- Focused suite: **8 runs, 67 assertions**, no failures/errors/skips (seed 46837). Related suite before the final cleanup regression and prompt assertions: **344 runs, 2,373 assertions**, no failures/errors/skips (seed 22290); the final focused/prompt checks cover those additions. Full repository verification follows step 9.
- Verified on macOS arm64; Linux remains unverified. Authority: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#exec and SCL 2.8.1 / 2.9.1.6.

## Step 9 verification — resource-limit inventory and arithmetic length

- Inventoried native arithmetic, parser/expansion, aliases, evaluation, substitution, matcher, pathname traversal, job records, PID spellings, descriptors, extension limits, executable-text detection, directory APIs, and adjacent host capture/history/context/lifecycle bounds in `doc/shell.md`. Read chunk sizes, ABI buffers and polling intervals are distinguished from cumulative quotas. Base-affecting safety policies apply to standalone as well as hosted execution and remain explicitly non-conforming; extension policies and genuine system constraints are separate.
- Added `test/test_native_shell_limits.rb`. Initial run: 4 tests, 1 assertion, 1 failure and 3 errors from the arithmetic byte/literal caps (seed 57816). Removed both lexer/parser expression-byte guards and replaced recursive left-spine evaluation with an iterative chain, keeping lazy right operands and assignment order. Integer spelling normalization discards leading zeros before precision checks and bounds conversion of significant digits.
- The old test asserting that a 4,097-byte addition must fail was replaced with an exact successful-result assertion. Its independent excessive-nesting and overflow assertions remain intact. An initial hosted test fixture used StringIO with external printf, which cannot be remapped to OS descriptors; the fixture now tests a hosted assignment and its stored arithmetic value directly, without changing process IO behavior.
- Focused limits suite: **4 runs, 25 assertions**, no failures/errors/skips (seed 58296). Existing native suite: **114 runs, 775 assertions**, no failures/errors/skips. Noexec/static syntax checks remain side-effect-free; existing capture, matcher, brace and nesting-bound regressions still pass.
- Final related shell suite covering steps 8 and 9: **349 runs, 2,410 assertions, no failures/errors/skips**, seed 43059, `/tmp/kward-step9-shell-final.log`.
- Full repository suite: **2,615 runs, 13,829 assertions, 1 failure, 0 errors, 2 skips**, seed 26466, `/tmp/kward-step9-full.log`. The only failure remains `TestEditorPrompt#test_editor_stays_visible_and_shows_spinner_while_agent_runs`, `test/test_editor_prompt.rb:109`, expected `· ·` versus `⠋`. Existing Bubblewrap integration skips remain; unrelated tests were not changed.
- `git diff --check` passed. Verified on macOS arm64 / Ruby 4.0.3; Linux verification remains pending. Step 8 was committed separately as `6dc9e32` (`fix(shell): recover safely from failed interactive exec`).
- Authorities: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html (2.3, 2.6.3/2.6.4, 2.7, 2.9, 2.14), and https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html (input files). This record does not close the remaining Base/UP/XSI audits or certify conformance.

## Step 10a verification — standalone history and fc

- Implemented lazy standalone history, numeric/relative/prefix selection, listing/reverse ranges, substitution, direct-argv editor invocation, assignment/redirection inheritance, failed-editor suppression, and private temporary cleanup. HISTFILE persistence is opt-in; HISTSIZE defaults to 512 and is sampled at initialization. Unsafe files fall back to memory, without chmod or following symlinks; forked copies cannot persist parent history.
- Added six history regressions. Initial four tests failed before implementation. Cancellation uses an isolated runtime with an injected interrupted editor; a first test fixture assumed Minitest `stub`, unavailable here, and was corrected to the repository's singleton-method pattern without changing assertions.
- Related shell suite: **355 runs, 2,446 assertions, no failures/errors/skips**, seed 50823 (`/tmp/kward-step10-history.log`). `git diff --check` passed. macOS arm64 / Ruby 4.0.3 verified; Linux remains pending.
- References: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fc.html and https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html. Step 10 remains open for editing, prompts/options, mail, and the remaining UP audit.

## Step 10b verification — prompts, EOF options, and mail

- Added PS1 parameter-then-exclamation passes, PS4 parameter expansion with safe diagnostic/fallback, no-op nolog, terminal ignoreeof, and monotonic MAILCHECK polling before primary prompts. MAILPATH precedence, escaped percent pathnames, creation/mtime tracking and parameter-only custom messages are covered. The initial non-terminal EOF exception was subsequently removed in step 10c: ignoreeof now waits without prompt spinning and remains responsive to exit traps.
- Initial interactive suite: 5 tests, 3 failures and 2 errors. After implementation: **5 runs, 32 assertions**, passing; includes a real PTY Ctrl+D/explicit-exit test. Existing ENV identity-gate and no-input-read-ahead tests remain unchanged.
- Related shell suite: **360 runs, 2,478 assertions, no failures/errors/skips**, seed 48681 (`/tmp/kward-step10-prompts.log`). macOS verified; Linux pending. vi editing and the remaining UP audit are still open.
- Authority: sh environment/extended description and SCL 2.5.3 / set in https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html .

## Step 10c verification — vi editing and final UP implementation review

- Added standalone vi insert/command modes, motion/operator families and counts, history navigation/pattern search, copy-before-edit undo, repeat across submissions, pathname completion/expansion, alias macros, comments, and private external-vi editing. Terminal handling is separate from edit state: one-byte reads, configured stty controls, scoped raw mode, safe horizontal rendering, and locale-aware characters/case/cell widths. Hosted activation is explicitly rejected.
- Added `test_native_shell_vi.rb`: **15 runs, 87 assertions**, passing (seed 1402). Coverage includes command families, history copies/search, repeat/counts, quoted interrupts, long lines, locale text, bounded recursive macros, pathname escaping and directory suffixes, default prompts, and hosted exclusion. Real-PTY coverage in `test_native_shell_interactive.rb` now has **10 runs, 55 assertions**, passing (seed 38038): editing/recall, interruption, custom stty, no command-stdin read-ahead, editor terminal restoration, setup-error recovery, and terminal/non-terminal ignoreeof.
- Removed the initial non-terminal ignoreeof exception after checking set's requirement: interactive EOF now waits without printing prompts repeatedly, polls signals, and accepts an explicit exit trap. Non-interactive script EOF remains unchanged.
- Review added forked-history ownership and FCEDIT non-evaluation regressions. A new byte-preservation regression initially failed with JSON::GeneratorError for a C-locale non-UTF-8 command; history now round-trips those bytes losslessly without weakening private-file checks. Final history suite: **9 runs, 46 assertions**, passing (seed 47246). Fresh private editor files are explicitly mode 0600 even under a restrictive inherited umask.
- The first combined vi suite exposed a real hosted ENOEXEC regression: TerminalSequences eagerly required bundled-gem base64 under `--disable=gems`. Its two encoding sites now use Ruby's equivalent `pack("m0")`, preserving outputs without that loading dependency. A standalone no-gems regression and the existing hosted executable-text ownership tests pass. No sandbox or process-group boundary was relaxed. PTY fixture synchronization was corrected for the renderer's explicit carriage return; assertions still require real command output and restored terminal behavior. The existing trace-copy assertion was preserved while adding PS4 guidance.
- RPC initialization explicitly reports history, lineEditing, and mailNotifications as unsupported. RPC server suite: **30 runs, 558 assertions**, passing (`/tmp/kward-step10-rpc.log`). Native standalone programs remain ordinary external commands under existing tool permissions; no terminal/history API was added to RPC.
- Final related shell suite: **383 runs, 2,606 assertions, no failures/errors/skips**, seed 23672, `/tmp/kward-step10-shell-final.log`.
- Final full repository suite: **2,649 runs, 14,028 assertions, 1 failure, 0 errors, 2 skips**, seed 5404, `/tmp/kward-step10-full-final.log`. The only failure remains `TestEditorPrompt#test_editor_stays_visible_and_shows_spinner_while_agent_runs`, `test/test_editor_prompt.rb:109`, expected `· ·` versus `⠋`. The existing Bubblewrap integration skips remain. No unrelated tests were changed.
- `git diff --check` passed. Verification is on macOS arm64 / Ruby 4.0.3. Docker still cannot reach `/Users/kwood/.docker/run/docker.sock`; Linux was not run. The vi macro safety policies (100 nested expansions, 1 MiB replacement bytes per edit line) remain disclosed UP restrictions, not OS limits. All requested implementation checkboxes are checked, but the UP profile completion gate remains open; neither UP nor full POSIX certification is claimed.
- Profile audit correction: Issue 8 marks `type` as XSI, not UP. Its remaining utility audit moved to XSI-3 for step 11/12; UP-10 now tracks prompt defaults. References: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html (complete vi command list), https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fc.html, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html (2.5.3 and set), and https://pubs.opengroup.org/onlinepubs/9799919799/utilities/type.html .
- Earlier step-10 commits: `8fd561df` (history/fc) and `b0d3950e` (prompts, mail, EOF options). Final review found no abandoned debug instrumentation or unrelated edits to retain.

## Step 11 verification — standardized resource limits and scoped XSI audit

- Corrected the initial plan's Issue 7 classification against Issue 8: `ulimit` is Base except CPU-time `-t`, and the standard now requires soft/hard/all and the core/data/file/descriptor/stack/address-space selectors. Implemented these in the existing native builtin owner, with decimal/unlimited operands, standard units, zero/large values, default soft queries and both-limit settings, and diagnostic failures. Additional Bash resource selectors remain unsupported.
- Limits use the operating system directly, in owned processes only. `Runtime` and `ScriptRunner` default to `process_owned: false`; standalone/native ENOEXEC bootstraps, the dedicated worker, and native script children opt in. A forked runtime copy can alter its own limits. Embedded callers may query but cannot mutate their host's limits. There is no temporary host-wide setting/restoration, no virtual hard-limit rollback, and no relaxation of sandbox, private protocol, or descendant ownership boundaries.
- Added `test_native_shell_ulimit.rb`. Initial implementation test run: **10 runs, 14 assertions, 10 failures**, all from missing ulimit support. Final standalone file: **15 runs, 191 assertions, no failures/errors/skips**, seed 25516; definitive final counts are also included in the combined suite below. Coverage includes all resource queries/soft round trips, soft/hard selection and failures, zero/large/invalid operands, actual 512-/1024-byte file-write enforcement in shell builtins and external children, reading larger existing files, subshell/pipeline/substitution/native-script isolation, exec/native ENOEXEC inheritance, failed interactive exec, and worker/embedding isolation. Even the embedded API mutation-denial test runs in a disposable process so a regression cannot lower the test runner's hard limit.
- The first post-implementation run had two fixture mismatches, not weakened behavior checks: the existing type format is `is shell builtin` (no article), and hosted captured output includes the echoed command line. Assertions now check that established format and the exact final result line.
- Scoped XSI review inspected SCL/sh and type/ulimit/echo/kill plus alias/unalias/cd/pwd/umask/getopts/read/jobs/fg/bg/wait/hash/command/test/printf markings. Added LIMIT-1 (Base) and split XSI-1 through XSI-6 rather than treating ulimit as the entire optional profile. Numeric trap/kill mappings, short symbolic kill forms, type's current-environment classifications, and missing/unknown operand behavior now have focused coverage. SCL set -h is already Base.
- The audit exposed two small actual bugs: `type` with no operand returned success, and kill rejected lowercase signal names despite -signal_name being equivalent to case-independent -s. Added failing regressions before the minimal fixes. Final `test_native_shell_xsi.rb`: **5 runs, 139 assertions, no failures/errors/skips**, seed 35399; definitive combined verification follows. Type originally failed its missing-operand case; the added kill test separately failed on `invalid signal: hup`. All actual signals target disposable shell processes; no unrelated process is signaled.
- Remaining XSI gaps are explicit: native diagnostics do not implement NLSPATH message-catalog lookup, and host-delegated echo on this macOS suppresses output for -n and prints a literal backslash for `echo 'a\nb'`, unlike XSI. Utility packaging/locale policy and platform verification remain open. No host echo behavior was changed, no unrelated utility rewrite was introduced, and no XSI/full POSIX conformance is claimed.
- Final related shell suite: **403 runs, 2,942 assertions, no failures/errors/skips**, seed 29634, `/tmp/kward-step11-shell-final.log`.
- Full repository suite: **2,669 runs, 14,364 assertions, 1 failure, 0 errors, 2 skips**, seed 51379, `/tmp/kward-step11-full.log`. The only failure remains `TestEditorPrompt#test_editor_stays_visible_and_shows_spinner_while_agent_runs`, `test/test_editor_prompt.rb:109`, expected `· ·` versus `⠋`. No unrelated test was changed. A separate verbose Bubblewrap run confirms the two existing disabled integration tests: `test_denied_child_network_cannot_connect_to_loopback` and `test_workspace_write_enforces_filesystem_boundary` (`/tmp/kward-step11-bubblewrap.log`).
- macOS arm64 / Ruby 4.0.3 verified. Docker still cannot connect to `/Users/kwood/.docker/run/docker.sock`; Linux verification was not run. Documentation, scoped shell-agent guidance, changelog, RPC boundary explanation, matrix and AGENTS guidance are updated. Existing RPC nativeScripting=false already explicitly excludes the persistent shell interface; no new RPC API is introduced. The full suite includes existing RPC capability coverage.
- Final diff review found only the implementation, entrypoint ownership plumbing, two audit fixes, regression tests and required documentation. No debug instrumentation, failed-hypothesis guard, unrelated formatting, or baseline-test adjustment remains. `git diff --check` passed.
- Authorities: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ulimit.html (including Issue 8 change history), https://pubs.opengroup.org/onlinepubs/9799919799/utilities/type.html, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/kill.html, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/echo.html, and https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html (2.5.3, set, trap). Step 11's requested implementation/audit work is recorded, but the XSI profile gate and step 12 remain open.
