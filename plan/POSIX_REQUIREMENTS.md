# kwsh POSIX.1-2024 requirement matrix

Use this matrix with [PLAN.md](PLAN.md). It records the starting audit and links each planned gap to an owner and verification work. It is not a certification claim or a substitute for the final clause-by-clause audit.

## Scope and status rules

- **Base**: shell language, `sh` invocation, and required shell utility contracts. External utilities can be supplied by the host; their availability and behavior still need an integration audit before claiming a complete execution environment.
- **UP**: User Portability Utilities, tracked separately from Base.
- **XSI**: XSI additions, tracked separately from Base and UP.
- **Hosted**: Kward's supervised `/shell`, not the standalone conformance target.

Statuses are deliberately explicit:

- **confirmed gap**: identified by the starting audit/code inspection; a focused failing regression must precede its fix.
- **implemented and tested**: only the narrowly described behavior is covered, not every requirement in the referenced clause.
- **not yet audited**: coverage may exist, but the full contract has not been checked.
- **permitted implementation choice**: the cited requirement allows the stated choice; other implementation-defined choices still need inventory.
- **optional profile**: UP/XSI work not yet complete; this is not a Base failure.
- **intentional hosted difference**: host lifecycle/security behavior that must remain separate.

Owners below are under `lib/kward/shell/`; test abbreviations name files under `test/`: **N** = `test_native_shell.rb`, **I** = `test_native_shell_invocation.rb`, **R** = `test_native_shell_runner.rb`, **P** = `test_native_shell_posix.rb`, **L** = `test_native_shell_locale.rb`, **M** = `test_native_shell_pattern.rb`, **H** = `test_persistent_shell_session.rb`. A test file listed as partial coverage is not evidence that an open gap passes.

## Primary references

- [SCL: Shell Command Language](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html) (section numbers below refer to this page).
- [sh](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sh.html): options, operands, stdin, environment, asynchronous events, and UP extended description.
- [XBD 3.10 Alias Name](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap03.html#tag_03_10).
- [XBD 8 Environment Variables](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap08.html), including locale precedence.
- Utility references in the tables link to their POSIX.1-2024 specifications.

## Initialization and invocation (plan step 2)

| ID | Requirement / POSIX reference | Profile | Owner | Coverage / verification needed | Status |
| --- | --- | --- | --- | --- | --- |
| INIT-1 | SCL 2.5.3 PPID: initialize parent PID; retain value in subshells | Base | `native_runtime.rb`, `native_substitution.rb` | I `test_startup_initializes_ppid_and_optind_in_clean_and_inherited_environments`, `test_startup_variables_are_available_in_file_and_stdin_modes` | implemented and tested |
| INIT-2 | [getopts](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/getopts.html): OPTIND starts at 1 on invocation | Base | `native_runtime.rb`, `native_builtins.rb` | I clean/inherited startup, file/stdin, `test_subshells_preserve_current_optind_without_resetting_parent_state` (including no default export); N/P getopts reset | implemented and tested |
| INIT-3 | SCL 2.5.3 PWD: preserve valid absolute inherited logical path without dot/dot-dot components; otherwise use physical path | Base | `native_runtime.rb` | I `test_startup_preserves_valid_logical_pwd_and_exports_it`, `test_startup_replaces_missing_or_invalid_pwd_with_physical_path`, `test_hosted_startup_keeps_the_explicit_workspace_root` | implemented and tested |
| INIT-4 | sh OPERANDS; SCL 2.5.2: default `$0` derives from invocation, command file or explicit command name | Base | `script_runner.rb`, `exe/kwsh` | I `test_default_zero_comes_from_invocation_and_explicit_command_names_win`, file operands and lone-dash stdin; R native exec fallback names | implemented and tested |
| INIT-5 | sh OPERANDS: ignore first `-` operand, then select file/command-string/stdin operands normally | Base | `script_runner.rb` | I `test_leading_dash_is_ignored_before_file_and_command_operands`, `test_lone_dash_still_reads_stdin_without_read_ahead`; undefined `-`/`--` combinations are not conformance assertions | implemented and tested |
| INIT-6 | SCL 2.5.3: reset IFS on invocation | Base | `native_runtime.rb` | P `test_invocation_resets_ifs_but_later_assignments_still_work` | implemented and tested |
| INV-1 | sh STDIN: do not consume input belonging to invoked commands | Base | `native_program.rb`, `script_runner.rb`, `native_fields.rb` | R `test_stdin_does_not_buffer_input_owned_by_read`; N read/external handoff | implemented and tested |
| INV-2 | sh OPTIONS/OPERANDS: grouped flags, options after `-c`/`-s`, explicit command names and arguments | Base | `script_runner.rb` | I `test_grouped_invocation_flags_and_options_after_c_or_s`; R command mode | implemented and tested |
| INV-3 | sh full invocation contract: input types, blocking FIFO/TTY reads, file search, exit/read-error statuses, empty input | Base | `script_runner.rb`, `native_program.rb` | I/R/P partial; enumerate missing cases in step 12 | not yet audited |

## Known base-shell gaps (steps 3–9)

| ID | Requirement / POSIX reference | Profile | Owner | Coverage / verification needed | Status |
| --- | --- | --- | --- | --- | --- |
| ALIAS-1 | XBD 3.10; [alias](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/alias.html): numeric names and permitted `!%,-@_` characters | Base | `native_runtime.rb`, `native_syntax.rb` | N/I substitution tests; add numeric and punctuation names (step 3) | confirmed gap |
| ALIAS-2 | alias STDOUT: quoted `name=value` output without `alias ` prefix; keep command-description output separate | Base | `native_runtime.rb`, `native_builtins.rb` | Add listing/lookup/round-trip cases (step 3); N command lookup partial | confirmed gap |
| TRACE-1 | SCL 2.15 set `-x`: trace assignment-only commands after expansion, before execution | Base | `native_runtime.rb` | Add assignment-only trace, order and stderr redirection cases (step 3) | confirmed gap |
| MASK-1 | [umask](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/umask.html), [chmod](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html) symbolic grammar: permission copies and operation combinations | Base | `native_builtins.rb` | N basic mask/host-isolation coverage; add `g=u`, compound modes and file effects (step 4) | confirmed gap |
| MASK-2 | umask OPTIONS: `--`, `-S` with mask; setting does not print query output | Base | `native_builtins.rb` | Add option/query/round-trip cases (step 4) | confirmed gap |
| CD-1 | [cd](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cd.html) `-P -e`: failure when changed directory cannot be determined | Base | `native_runtime.rb` | I cdpath/grouped pwd partial; add controlled physical-path failure and last-option-wins cases (step 4) | confirmed gap |
| CD-2 | cd algorithm: validate preceding component before removing `..` | Base | `native_runtime.rb` | Add missing/non-directory/symlink traversal (step 5) | confirmed gap |
| CWD-1 | SCL 2.13 execution environment; cd: retain actual directory identity across rename | Base | `native_runtime.rb`, `native_process.rb`, redirection/expansion owners | Add rename then external command, subshell, source, redirect, glob and deleted-directory cases; verify handle cleanup (step 5) | confirmed gap |
| FD-1 | SCL 2.7, 2.13: inherited descriptors available to redirection/children | Base | `script_runner.rb`, `native_runtime.rb`, `native_process.rb`, `native_substitution.rb` | N created/duplicated descriptors only; add inherited 3–9 read/write/close/exec/ENOEXEC fixtures (step 6) | confirmed gap |
| SIG-1 | sh ASYNCHRONOUS EVENTS: interactive TERM/QUIT defaults; monitor TTIN/TTOU/TSTP handling | Base | `native_traps.rb`, `native_jobs.rb`, `script_runner.rb` | I prompt tests and H job control partial; isolated signal/INT regressions needed (step 7) | confirmed gap |
| SIG-2 | SCL 2.15 trap: non-interactive inherited ignored dispositions cannot be changed | Base | `native_traps.rb`, `native_process.rb` | N trap tests partial; inherited ignored signal subprocess fixtures needed (step 7) | confirmed gap |
| SIG-3 | SCL 2.15 trap `-p`: defaults, ignored signals, explicit requests and restorable output | Base | `native_traps.rb` | N listing tests cover registered traps only; add defaults and restoration (step 7) | confirmed gap |
| SIG-4 | SCL 2.13/2.15 trap: saved trap inspection in subshells/substitutions distinct from execution dispositions | Base | `native_traps.rb`, `native_substitution.rb` | Add `saved=$(trap -p)` / `eval "$saved"`, nested subshell inspection (step 7) | confirmed gap |
| EXEC-1 | SCL 2.8.1, 2.15 exec: interactive failure must not exit shell | Base | `native_builtins.rb`, `native_process.rb`, `script_runner.rb` | R successful PID replacement/non-interactive failure; add missing PATH/pathname/unexecutable failure, descriptor/cwd recovery (step 8) | confirmed gap |
| LIMIT-1 | SCL 2.6.4 arithmetic: otherwise valid expressions exceed artificial 4,096-byte quota | Base | `native_arithmetic.rb` | N `test_arithmetic_limits_nesting_expression_length_and_result_size` proves quota, not conformance; add long non-overflowing expression (step 9) | confirmed gap |
| LIMIT-2 | SCL 2.3, 2.6, 2.7, 2.9, 2.14; sh INPUT FILES: full size/depth/work quota inventory and classification | Base | `native_syntax.rb`, `native_arithmetic.rb`, `native_substitution.rb`, `native_pattern.rb`, `native_glob.rb`, `native_jobs.rb` | N/M safety bounds covered; classify each as permitted/system/product policy and test standalone/host distinction (step 9) | not yet audited |
| FD-2 | SCL 2.7: maximum supported descriptor must be at least 9; >9 not required | Base | `native_runtime.rb`, `native_process.rb` | N high-descriptor tests cover extension; inherited 0–9 remains FD-1 | permitted implementation choice |

## Language and execution audit backlog (step 12)

These broad entries are deliberately **not yet audited** even where many regressions pass. Split them into narrower requirements as the audit progresses; do not close a whole clause based on one representative case.

| ID | Requirement / POSIX reference | Profile | Owner | Existing partial coverage / remaining audit | Status |
| --- | --- | --- | --- | --- | --- |
| LANG-1 | SCL 2.2: escape, single/double/dollar-single quotes, here-doc quoting | Base | `native_syntax.rb`, `native_expansion.rb` | N/P quoting, dollar escapes, here-docs; full byte/quote interaction audit | not yet audited |
| LANG-2 | SCL 2.3–2.4, 2.10: tokens, reserved words, grammar, incremental parsing and alias substitution | Base | `native_syntax.rb`, `native_program.rb` | N/I/P aliases, incomplete input, noexec; ALIAS-1/2 and limit review remain | not yet audited |
| LANG-3 | SCL 2.5: positional/special parameters, environment names, export attributes, variables | Base; UP LINENO separate | `native_runtime.rb`, `native_expansion.rb` | N/P argument and environment tests; INIT entries plus full variable audit | not yet audited |
| EXP-1 | SCL 2.6.1–2.6.2: tilde, parameter defaults/errors/assignment/length/trimming | Base | `native_expansion.rb`, `native_fields.rb`, `native_pattern.rb` | N/P lazy/unset/quote/length tests; full interaction audit | not yet audited |
| EXP-2 | SCL 2.6.3: substitution nesting, newline removal, status and subshell environment | Base | `native_substitution.rb`, `native_syntax.rb` | N/P substitution/status tests; traps and quota audit remain | not yet audited |
| EXP-3 | SCL 2.6.4: arithmetic syntax, precision, operators and expansion order | Base | `native_arithmetic.rb`, `native_expansion.rb` | N/P lazy arithmetic, substitution once, division; LIMIT-1 and precision documentation | not yet audited |
| EXP-4 | SCL 2.6.5–2.6.7: IFS splitting, pathname expansion and quote removal/order | Base | `native_fields.rb`, `native_glob.rb`, `native_expansion.rb` | N/P quoting, empty fields, globbing; exhaustive combination audit | not yet audited |
| REDIR-1 | SCL 2.7: all redirect operators, expansion, order, noclobber, here-documents and errors | Base | `native_runtime.rb`, `native_syntax.rb` | N/P descriptor/redirection/here-doc cases; FD-1 and filesystem races remain | not yet audited |
| EXEC-2 | SCL 2.8: statuses, error consequences and interactive/non-interactive recovery | Base | `native_runtime.rb`, `native_builtins.rb`, `script_runner.rb` | P fatal/ordinary/conditional errors; EXEC-1 and invocation errors remain | not yet audited |
| EXEC-3 | SCL 2.9.1: assignments, declaration utilities, command search, ENOEXEC | Base | `native_runtime.rb`, `native_process.rb`, `native_builtins.rb` | N/I/P export/readonly, search, native fallback; complete precedence/error audit | not yet audited |
| EXEC-4 | SCL 2.9.2–2.9.3: pipelines, AND-OR/sequential/asynchronous lists | Base | `native_runtime.rb`, `native_jobs.rb` | N/P concurrent pipelines, job statuses, conditions; signal/wait interaction audit | not yet audited |
| EXEC-5 | SCL 2.9.4–2.9.5: compound commands, loops, case, functions | Base | `native_runtime.rb`, `native_syntax.rb` | N/P control-flow/function argument scope; full grammar and error audit | not yet audited |
| EXEC-6 | SCL 2.11–2.13: job control, signals, shell/subshell execution environments | Base | `native_jobs.rb`, `native_traps.rb`, `native_substitution.rb` | N/I/R/H job/trap/exec coverage; SIG/CWD/FD entries remain | not yet audited |
| LOCALE-1 | SCL 2.14; XBD 8.2: wildcard/bracket matching, classes, ranges, collating symbols/equivalence | Base | `native_pattern.rb`, `native_locale.rb`, `native_glob.rb` | M deterministic frontier; L installed locales; N locale integration. Audit encodings/locale availability on macOS and Linux | not yet audited |
| LOCALE-2 | SCL 2.5.3; sh ENVIRONMENT: locale precedence, startup lexical LC_CTYPE, LC_MESSAGES | Base | `native_locale.rb`, `native_syntax.rb`, runtime diagnostics | L category restoration and R C-locale Unicode partial; lexical/diagnostic locale audit needed | not yet audited |

## Required utility contracts

Each name is an independent audit target, even in grouped rows. Audit required options, operands, output, exit statuses and error consequences; existing builtin support does not close these rows. References for special builtins are SCL 2.15; other links are utility-specific. Job-control utilities' applicability also needs checking against the selected platform options.

| ID | Requirement / POSIX reference | Profile | Owner | Coverage / remaining audit | Status |
| --- | --- | --- | --- | --- | --- |
| UTIL-1 | SCL 2.15: `break`, `:`, `continue`, `.`, `eval`, `exit`, `return`, `shift`, `times` | Base | `native_runtime.rb`, `native_builtins.rb` | N loops/source/eval; I times; R exit; audit every contract individually | not yet audited |
| UTIL-2 | SCL 2.15: `export`, `readonly`, `unset`, `set` | Base (UP options below) | `native_runtime.rb`, `native_builtins.rb` | N/I/P attributes, declarations, options; all option and error combinations | not yet audited |
| UTIL-3 | SCL 2.15: `exec`, `trap` | Base | `native_builtins.rb`, `native_traps.rb` | N/R; EXEC-1, SIG-2/3/4 | not yet audited |
| UTIL-4 | [alias](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/alias.html), [unalias](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/unalias.html), [command](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/command.html), [hash](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/hash.html) | Base | `native_runtime.rb`, `native_builtins.rb` | N/I command/path/cache tests; ALIAS gaps and full description formats | not yet audited |
| UTIL-5 | [cd](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cd.html), [pwd](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pwd.html), [umask](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/umask.html) | Base | `native_runtime.rb`, `native_builtins.rb` | N/I masks/CDPATH; CD/CWD/MASK gaps, permission/race fixtures | not yet audited |
| UTIL-6 | [getopts](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/getopts.html), [read](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/read.html) | Base | `native_builtins.rb`, `native_runtime.rb`, `native_fields.rb` | N/P options/reset, IFS/read; INIT-2 and full error contracts | not yet audited |
| UTIL-7 | [jobs](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/jobs.html), [fg](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fg.html), [bg](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/bg.html), [wait](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/wait.html), [kill](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/kill.html) | Base / applicable job-control option | `native_jobs.rb`, `native_traps.rb` | N/R/H groups, wait, stops, signals; full utility and platform option audit | not yet audited |
| UTIL-8 | [true](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/true.html), [false](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/false.html), [echo](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/echo.html), [printf](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/printf.html), [test](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/test.html) / `[` | Base; echo XSI additions separately | `native_runtime.rb`, `native_process.rb`, host utilities | N/P exercise commands; inventory builtin/external availability and host dependencies, do not assume host conformance | not yet audited |
| UTIL-9 | SCL 2.9.1.4 command search: standard utility execution environment, remaining host utilities | Base / selected utility options | `native_process.rb`, `native_runtime.rb`, platform packaging | Inventory required PATH utilities and supported OS behavior in step 12 | not yet audited |

## Optional profiles (steps 10–11)

| ID | Requirement / POSIX reference | Profile | Owner | Coverage / verification needed | Status |
| --- | --- | --- | --- | --- | --- |
| UP-1 | sh history; [fc](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fc.html); HISTFILE/HISTSIZE/FCEDIT | UP | `script_runner.rb`, future history owner | No native history/fc contract tests; add private storage/editor/cancellation/failed-editor cases (step 10) | optional profile |
| UP-2 | sh vi editing; SCL set `-o vi` | UP | `script_runner.rb`, future line editor | No native vi mode; not Kward composer editing (step 10) | optional profile |
| UP-3 | SCL set `-o ignoreeof` | UP | `native_builtins.rb`, `script_runner.rb` | Not accepted; terminal EOF regression needed (step 10) | optional profile |
| UP-4 | SCL set `-o nolog` (permitted no-op) | UP | `native_builtins.rb` | Not accepted; option round-trip coverage needed (step 10) | optional profile |
| UP-5 | SCL 2.5.3 PS1 `!` / `!!` history expansion | UP | `script_runner.rb` | I parameter prompts only; add history-number expansion (step 10) | optional profile |
| UP-6 | SCL 2.5.3 PS4 parameter expansion for traces | UP | `native_runtime.rb`, `native_expansion.rb` | Hard-coded `+ `; add expansion/no command-evaluation cases (step 10) | optional profile |
| UP-7 | sh MAIL/MAILPATH/MAILCHECK notification | UP | `script_runner.rb`, future notification owner | No implementation/coverage; test interval, precedence and message expansion (step 10) | optional profile |
| UP-8 | sh ENV startup: interactive only, parameter expansion, real/effective identity gate | UP | `script_runner.rb` | I `test_env_startup_is_parameter_expanded_and_interactive_only`, identity/substitution test | implemented and tested |
| UP-9 | SCL 2.5.3 LINENO: script/function source lines | UP | `native_syntax.rb`, `native_runtime.rb`, `native_program.rb` | P `test_lineno_tracks_incremental_input_functions_and_nested_commands` | implemented and tested |
| UP-10 | [type](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/type.html), remaining UP utility details and prompt defaults | UP | `native_builtins.rb`, `script_runner.rb` | I type/prompts partial; complete selected-profile audit | not yet audited |
| XSI-1 | [ulimit](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ulimit.html): file size units/options/query/set/inheritance | XSI | `native_builtins.rb`, `native_process.rb` | Explicitly unsupported; isolated small-file and subshell/host tests needed (step 11) | optional profile |
| XSI-2 | SCL 2.5.3/sh NLSPATH; remaining XSI shell/utility additions | XSI | `native_locale.rb`, diagnostics, utility owners | Audit all applicable XSI shading, including echo, before closing profile (step 11/12) | not yet audited |

## Hosted differences and final milestones

| ID | Requirement / reference | Profile | Owner | Coverage / verification needed | Status |
| --- | --- | --- | --- | --- | --- |
| HOST-1 | SCL 2.12–2.13 vs reserved shutdown signal and tab-owned descendant cleanup | Hosted | `native_worker.rb`, `native_jobs.rb`, `native_traps.rb` | H shutdown/cancellation; I standalone USR2; retain bounded child cleanup | intentional hosted difference |
| HOST-2 | SCL exec vs supervised hosted execution preserving private protocol | Hosted | `native_process.rb`, `native_builtins.rb`, `native_worker.rb` | N/H hosted exec vs R standalone PID replacement | intentional hosted difference |
| HOST-3 | Directory, descriptor and quota policies must not weaken host workspace/sandbox boundaries | Hosted | `persistent_session.rb`, `native_worker.rb`, runtime/process owners | H plus sandbox tests; recheck with steps 5/6/9 | intentional hosted difference |

Milestones remain separate:

1. **Base**: close confirmed Base gaps, split/audit broad language/utility/locale rows, justify every limit and implementation-defined choice. Not complete.
2. **UP**: complete UP-1 through UP-10 or explicitly decline the profile. Not complete.
3. **XSI**: complete XSI-1 and audit XSI-2 independently of UP. Not complete.
4. **Final audit (step 12)**: review every utility contract and expansion interaction; signals/jobs/wait; permissions/symlinks/renames/deletions/races; macOS and Linux locales/encodings; independent conformance tests and their assumptions; fresh full/focused test results and skips. Add newly discovered requirements instead of assuming this matrix is exhaustive. Publish a support statement distinguishing all three milestones and hosted exceptions. Formal certification is separate.
