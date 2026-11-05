# AGENTS.md

Guidance for AI coding agents working in this repository.

This is a living document. If significant changes to the codebase, architecture, commands, workflows, or project conventions occur, update this file so future agents start with accurate guidance.

## Project overview

Kward is an extendable Ruby CLI coding agent. It supports interactive and one-shot chat, local workspace tools, configurable prompts/skills, image attachments, web search, OpenAI OAuth/API-key authentication, session persistence, and a JSON-RPC backend for UI clients.

## Working style

- Make the smallest correct change for the request.
- Inspect relevant files before editing, and preserve existing style and naming.
- Prefer straightforward Ruby from the standard library unless an existing dependency is already used.
- Internal requires should target canonical implementations under domain folders. Keep the documented public `plugin_registry.rb` entrypoint.
- Keep user-facing behavior consistent with existing docs and tests.
- Do not introduce broad rewrites, formatting-only churn, or unrelated cleanup.
- Do not split large orchestration files such as `RPC::SessionManager` or `Model::Client` just because they are large; extract only when a behavior change exposes a clear, tested ownership boundary.
- Be careful with auth tokens, API keys, config files, session data, user prompts, and workspace file contents. Do not log secrets.

## Important paths

- `lib/main.rb` - executable entrypoint.
- `lib/kward/cli.rb` - command-line flow and interactive chat orchestration.
- `lib/kward/prompt_interface.rb` and `lib/kward/prompt_interface/` - terminal UI state, rendering, input, and built-in editor mechanics.
- `lib/kward/sessions/store.rb` - authoritative JSONL session persistence and conversation reconstruction.
- `lib/kward/sessions/catalog.rb` - rebuildable, fingerprint-validated session-list summary cache; JSONL sessions remain authoritative.
- `lib/kward/tabs/driver.rb` - session and plugin tab-driver boundary used by interactive tabs.
- `lib/kward/plugins/registry.rb`, `lib/kward/plugins/actions.rb`, `lib/kward/plugins/host.rb`, `lib/kward/plugins/http_server.rb`, `lib/kward/plugins/codex_responses.rb`, `lib/kward/plugins/resources.rb`, `lib/kward/plugins/chat_runtime.rb`, and `lib/kward/tools/plugin_tool.rb` - trusted plugin registration, typed command/action/startup-option contracts, identified-plugin host services, managed loopback HTTP and Codex Responses access, owned task/cleanup lifecycles, frontend-neutral plugin-chat execution, and model-callable plugin-tool adaptation.
- `examples/plugins/openrouter_proxy/` - example local OpenRouter Chat Completions proxy backed by Kward's normal Codex provider client, plus deterministic local fake embeddings.
- `lib/kward/workspace/git_worktree_manager.rb` - Git worktree discovery, creation, validation, and removal mechanics.
- `lib/kward/tools/workspace_targets.rb` - host-scoped workspace-role routing for model tools in linked worktree tabs.
- `lib/kward/cli/worktrees.rb` - interactive session-tab worktree binding and workspace re-rooting orchestration.
- `lib/kward/shell/kwsh.rb`, `lib/kward/shell/kwshrc.rb`, and `lib/kward/shell/persistent_session.rb` - one-off command routing/completion, declarative rc parsing, and persistent native-shell host/PTY lifecycle.
- `lib/kward/shell/native_syntax.rb`, `native_runtime.rb`, `native_process.rb`, and `native_worker.rb` - quote-preserving native kwsh parser, stateful interpreter, direct `execve` boundary, and single-threaded worker with a private control socket. Native `/shell` programs never implicitly fall back to another shell.
- `lib/kward/shell/native_expansion.rb`, `native_fields.rb`, and `native_pattern.rb` - lazy parameter expansion, shared quote-aware IFS splitting for expansion/read, and string-pattern matching for case/parameter trimming. Keep expansion operands parsed without evaluating them, preserve unset versus empty values, and never reparse expanded data as commands. `read` must not buffer beyond its logical line because subsequent commands can inherit the same descriptor. Track staged POSIX/Bash-extension work in `doc/shell.md`; roadmap entries are not implemented capabilities.
- `lib/kward/shell/native_substitution.rb`, `native_arrays.rb`, `native_braces.rb`, `native_condition.rb`, and `native_builtins.rb` - native fork/capture/descriptor lifecycles and scoped language mechanics. Keep process-substitution endpoints command-owned, output capture bounded, and command data distinct from explicitly parsed source.
- `lib/kward/shell/native_jobs.rb` and `native_traps.rb` - owned job groups, PTY foreground transfer, stopped-job state, deferred native signal handlers, and EXIT traps. Keep hosted shutdown untrappable (worker USR2), child groups owned, and standalone exec replacement separate from the hosted protocol-preserving equivalent. Never leave hosted descendants running after shell close.
- `lib/kward/shell/native_program.rb`, `native_locale.rb`, and `native_glob.rb` - incremental source reading without stdin read-ahead, scoped libc locale objects (macOS/Linux), and bounded pathname traversal sharing the string matcher. Alias substitution is parse-time and shares the input lexer (including quotes/here-documents); track replacement provenance and bounds, and never reinterpret expanded command data. Do not use process-global setlocale or recursive libc wildcard matching. Multi-character collation uses a bounded iterative frontier and isolated libc bracket/ordering primitives; keep candidate data from becoming libc wildcard source. Incremental parsing distinguishes a pending continued line from actual EOF. The requirement-linked POSIX and invocation suites complement deterministic matcher and optional installed-locale integration tests; do not equate passing regressions with certification.
- `plan/PLAN.md` and `plan/POSIX_REQUIREMENTS.md` - POSIX.1-2024 implementation steps, baseline verification, and requirement/status matrix. Keep Base, UP, XSI and intentional hosted differences separate; partial regression coverage must not close unaudited requirements.
- `exe/kwsh` and `lib/kward/shell/script_runner.rb` - standalone native file, `-c`, stdin, and plain interactive execution without loading the agent. Stdin must not read ahead of commands. Runtime startup initializes PPID/OPTIND once, retaining them in subshells; standalone inherited PWD must identify the runtime directory without dot/dot-dot components, while hosted startup keeps its explicit workspace root. Derive default `$0` from invocation and ignore a leading `-` operand before selecting the input mode's operands. Standalone interactive state is distinct from hosted ownership: keep ENV startup identity-gated, expand only parameters in ENV/prompts, and do not reserve hosted shutdown signals or impose tab cleanup on standalone sessions.
- `lib/kward/shell/native_arithmetic.rb` - bounded integer-only `$((...))` parsing and evaluation. Keep syntax validation independent of variable lookup, preserve truncation-toward-zero division, and never use Ruby or shell eval. Arithmetic ASTs now own lvalues, lazy logical/conditional evaluation, recursive arithmetic-only variable values, and bounded exponentiation; arithmetic expansions retain shell-substitution ASTs and expand them once before integer evaluation. Static syntax checks and noexec must never execute substitutions; expanded data and recursive variable values remain arithmetic-only. Command nodes retain source lines for LINENO, including incremental input.
- `lib/kward/pty/detached_run.rb` - shared lifecycle for commands detached from terminal ownership while remaining owned by a tab.
- `lib/kward/shell/prompt.rb` and `lib/kward/shell/prompt_session.rb` - transient shell-agent prompt context and scoped actions.
- `lib/kward/agent.rb` - agent loop and tool execution flow.
- `lib/kward/model/` - model provider HTTP client and stream parsing behavior.
- `lib/kward/auth/` - OAuth providers and auth credential file helpers.
- `lib/kward/tools/registry.rb` - tool dispatch and schema exposure.
- `lib/kward/tools/` - individual tool implementations, one file per tool.
- `lib/kward/mcp/` - local MCP client transports and configured server clients.
- `lib/kward/transport.rb` and `lib/kward/transport/` - frontend-neutral transport contracts, host, session gateway, persistent state, lifecycle manager, and foreground runtime.
- `lib/kward/transcripts/` - shared Markdown, HTML, and safe-path transcript export mechanics.
- `lib/kward/cli/transports.rb` - transport listing, status, and foreground-run commands.
- `lib/kward/rpc/` - JSON-RPC backend.
- `lib/kward/prompts.rb` - system prompt and skill catalog prompt assembly.
- `lib/kward/config_files.rb` - config path handling.
- `lib/kward/skills/` - Agent Skills discovery, parsing, validation, activation reads, and saved-session skill capture.
- `test/` - Minitest coverage.
- `doc/` - user documentation and generated docs source pages.
- `doc/api.md` - curated API reference overview used as the API docs landing page.
- `doc/platform-support.md` - supported operating systems, terminals, and sandbox backends.
- `CONTRIBUTING.md`, `SECURITY.md`, and `CODE_OF_CONDUCT.md` - contribution workflow and project trust policies.
- `templates/default/kward_navigation.rb` - shared generated-docs navigation data for guide/API dropdowns.
- `templates/default/layout/` - YARD layout templates for normal generated docs pages.
- `templates/default/fulldoc/` - YARD templates for generated full-list pages such as class, method, and file indexes.

## Common commands

Install dependencies:

```bash
bundle install
```

Run the full test suite:

```bash
ruby -Itest -e 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
```

Run one test file:

```bash
ruby -Itest test/test_cli.rb
```

Run the CLI locally:

```bash
ruby lib/main.rb
ruby lib/main.rb "Explain this project"
```

Benchmark composer hot paths:

```bash
script/benchmark_composer
```

Prepare and push a release after synchronizing `main` with `origin/main`:

```bash
script/release VERSION
```

## Implementation notes

- `ModelInfo.default_selectable_model?` owns default-picker eligibility. RPC model lists remain complete and expose `defaultSelectable` relative to the process default; the TUI uses its conversation selection. `Client#refresh_model_catalog` refreshes only the targeted provider and reports safe `success`/`unsupported`/`failed` metadata, retaining fallback catalogs on failure. Keep discovery separate from config/plugin reload; external clients explicitly use `runtime/reload` then `models/list` to adopt cross-process changes.
- This project uses Minitest. Add or update focused tests for behavior changes.
- Network/auth behavior should be easy to test without real external calls; follow existing test patterns and stubs.
- Keep CLI output stable unless the task is explicitly about UX copy.
- `TurnSummary` aggregates main-agent request usage, excluding auxiliary compaction/memory calls. `Agent` emits `Events::TurnSummary` even for interrupted started turns; `Conversation#finish_turn` attaches display-only metadata and `SessionStore` persists a `turn_summary` record anchored by `targetId` without advancing the branch leaf. Keep summaries out of model context, restore them by branch, and preserve RPC/Pan/export parity. `transcript.turn_stats` controls presentation, not data collection; filter output stays answer-only.
- Keep documentation current when behavior, configuration, extension points, commands, tools, RPC capabilities, or generated docs navigation changes.
- Add user-facing changes to the `CHANGELOG.md` `[Unreleased]` section using grouped `### Added`, `### Changed`, `### Fixed`, or `### Removed` subsections.
- When adding configuration, document default behavior and environment variable interactions.
- When adding tools, keep tool schemas, argument validation, execution, and tests aligned.
- When changing prompt/skill behavior, update `doc/extensibility.md`, `doc/skills.md`, CLI/RPC/Pan exposure, compaction behavior when activated instructions are durable, and prompt-related tests as needed. Skill capture sends the complete selected persisted session branch to the active model provider, must stay personal-skill-only, and requires editable review before an explicit save.
- Keep terminal text ownership centralized: `TerminalSequences` owns terminal output/control sequences, `TerminalKeys` owns input key byte sequences and key parser regexes, `ANSI` owns styling plus escape-aware transcript stripping/sanitizing/wrapping, `TerminalText` owns Unicode cell widths and grapheme-aware composer layout, and `PromptInterface::KeyHandler` owns input reading, tokenization, queueing, parsing, and dispatch mechanics.
- TUI handoffs that reserve tab shortcuts also reserve keyboard encoding. `PromptInterface::TerminalHandoffOutput` filters child Kitty keyboard stack/set and xterm modifyOtherKeys mutations with bounded incremental parsing, preserves terminal-string payloads, and reasserts flags without pushing after resets/screen switches. Always cancel unfinished controls and restore composer modes before handback redraw; do not infer recovery from one exact child reset sequence. Handoff input must preserve split CSI sequences and treat bracketed paste as data, not tab actions. This is best-effort terminal recovery, not a sandbox or full child keyboard-protocol virtualization.
- Vibe `:prompt <instruction>` and Modern `Ctrl+.` prompt lines run an interactive, editor-scoped agent turn. The model receives the active in-memory buffer and can use only the transactional `replace_editor_buffer` tool; commit generated content back to the editor as one undoable change and leave disk persistence to the user's normal save command. Keep this TUI-only until an equivalent editor capability exists for other frontends.
- Editor runners execute the current in-memory buffer for scratchpads and normal editable files. Keep runner binaries configured under `editor.runners`, resolve relative binaries from the active workspace, invoke them directly without a shell, and preserve bounded capture plus cancellation. JavaScript and TypeScript use Node by default; compiler-backed languages need explicit runner mechanics before becoming runnable.
- Inline image capability detection should prefer an active Kitty graphics probe on real TTYs, use recognized terminal hints when probing is inconclusive, retry transient detection failures, and fail closed for unknown terminals. Keep Kitty payloads protocol-valid, chunked, and response-suppressed so terminal acknowledgements do not enter the composer, and keep protocol-specific encoding in `TerminalSequences`.
- User-entered external `/shell` commands and `!command` use adaptive interactive PTY handoff by default: conservative line/progress controls and synchronized-output brackets render above a frozen composer, while screen-oriented or unknown controls trigger permanent full-terminal passthrough for that command. Keep the output classifier byte-preserving and incremental across chunks, close unterminated synchronized output before handback or exclusive transition, suppress Kward rendering throughout child ownership, and retain at most bounded transcript-safe output captured before the first forwarded input byte. Normalize carriage-return and horizontal-cursor progress to its final visible line for transient reconstruction. Tab shortcuts detach running shell commands into their originating tab's bounded background state rather than cancelling them; only explicit cancellation or shutdown terminates detached work. `/shell` owns a persistent local shell session; `capture <command>` retains bounded, sanitized output, while `/capture <command>` provides bounded one-shot transcript output. A leading `?` inside `/shell` runs a transient per-tab shell-agent turn; pass only bounded, sanitized last-command context, route explicit execution through the active shell session, and use `prepare_shell_command` for drafts that must remain unexecuted until the user presses Enter. Keep ordinary model-requested and RPC `run_shell_command` workers captured, cancellable, sandbox-aware, and noninteractive; the explicit `?` shell prompt is the user-directed exception that runs through the host-owned shell session. SSH remains a terminal-owned follow-up boundary rather than a shell-agent session.
- Identified plugins declare stable `id`, `version`, and plugin API metadata and receive shared configuration, private storage, secret lookup, logging, lifecycle callbacks, cooperative background tasks, managed cleanup, a loopback-only HTTP listener, and Codex streaming through Kward's normal model client. That path uses the existing private Codex backend endpoint; keep this dependency explicit and do not expose credentials to plugins. Plugins may declare no-argument `plugin.startup_option` switches; CLI discovery loads declarations before dispatch but runs lifecycle callbacks and the selected handler only for the chosen mode. Keep loading side-effect-free, invoke reload callbacks on the old registry before cleanup, bound shutdown waits without forcibly killing plugin threads, keep private config out of RPC/status output, scope durable state by stable plugin ID under the active config directory, and preserve anonymous legacy plugin loading.
- Plugin footer status is composable through identified `plugin.status` registrations with stable names, display order, and low/normal/high priority. Keep renderer failures isolated, remove whole low-priority segments first on narrow terminals, preserve aggregate text plus structured segments over RPC, and retain anonymous `plugin.footer` as a backward-compatible normal-priority contribution.
- Plugins may register model-callable tools through `plugin.tool`. Keep plugin tool schemas strict, route them through the normal `ToolRegistry` permission/hook/compaction path, expose them in normal CLI/RPC/Pan/transport-backed agent turns, honor execution-profile tool filtering, and keep them unavailable to editor prompts, shell-agent prompts, strict worktree agents, and plugin-owned chats unless those chats explicitly provide their own tools.
- Plugin commands and tools receive structured frontend-neutral UI through `ctx.ui`. Keep blocking question/select/confirm/input requests capability-gated and fail-closed, preserve cancellation, bound untrusted client answers, use asynchronous `turns/start` rather than synchronous `commands/run` for RPC interaction, render progress/notifications through synchronized TUI output, keep their RPC notifications structured, and let transport gateways route only answerable interaction requests.
- Typed plugin commands use strict object schemas, shell-style TUI arguments, optional declared positionals, and structured `ctx.result` values while preserving raw-string legacy commands. Identified plugins may register namespaced RPC-only actions through `plugin.action`; keep action arguments object-only, action results JSON-compatible, blocking UI disabled on synchronous RPC execution, and execution-profile plugin-command restrictions enforced.
- Session plugin commands may stage one `ctx.request_turn(system: text)` request, bounded to 65,536 bytes. Dispatch only after successful handler completion through the normal TUI/RPC session turn lifecycle, retaining origin-tab ownership, cancellation, hooks, tools, and execution profiles. `Conversation#with_system_turn` owns the transient system overlay; persist `plugin_system_turn` history metadata for display but exclude expired instructions from model replay and compaction. Only asynchronous session command contexts expose `turn_requests_supported?`; synchronous RPC, actions, tools, hooks, plugin chats, editor/shell prompts, and Pan remain unsupported. Preserve the current command's position in model context: Responses adapters send turn instructions as ordered input messages, using `developer` for Codex (its subscription endpoint rejects inline `system`) and `system` for direct OpenAI. Keep base instructions in the preamble. Anthropic/Gemini use separate system fields and require existing dialogue; never synthesize a user prompt to hide that limitation.
- Plugin-owned tabs register through `plugin.tab_type`, open through `/tab open <name>`, and own their transcript and turn behavior. Keep their drivers independent of workspace sessions, agents, prompts, and tools; the interactive tab host owns composer, rendering, streaming, cancellation, and layouts. Versioned chat contracts declare attachment, steering, and transcript-paging capabilities; preserve legacy method probing when no contract is declared. `PluginTabHost` provides immutable plugin config, secrets, logging, and durable storage isolated by plugin ID, chat type, and persisted scope, plus local/RPC/transport surface context and managed cleanup. Plugin tabs opt into RPC explicitly with `rpc: true`; they opt into external targeting separately with `transport: true`. `PluginChatRuntime` owns shared scoped turn queues, actor context, events, attachments, replay, and cancellation; RPC and transport adapters remain frontend facades without creating workspace sessions.
- External transports register through `plugin.transport`, use `Transport::Host` for normal Kward sessions or explicitly transport-capable plugin chats, persist namespaced state under the config directory, and implement explicit `start`/`stop` lifecycle methods. Transport plugins are trusted local code; remote identities still require host policy checks. Plugin-chat drivers may receive authenticated actor context but must enforce scope and ownership in trusted code. Execution profiles enforce generic session restrictions; plugin-owned tools and memory require their own explicit policy. Isolated transports should use a dedicated process/config root for strong separation.
- Normal session tabs may persist a Git worktree binding in their tab descriptor. Active worktree tabs rebuild their conversation and agent against the linked root, force workspace path guards and strict model-command sandboxing, and keep MCP clients and lifecycle hooks disabled for that strict agent. Their core workspace tools may target the active worktree or its verified `origin` role without target-specific authorization; the normal configured tool-permission policy applies equally to both. Keep each role separately path-guarded and shell-sandboxed, and keep generic shell commands unable to write shared Git metadata. RPC reports worktree bindings as interactive-TUI-only until an equivalent session API exists.

- Native `/shell` owns a deliberately limited POSIX-style language, not full POSIX/Bash compatibility. Keep syntax validation side-effect-free, quoted word parts intact until expansion, interpreter state authoritative, and unsupported constructs explicit errors. `NativeProcess` uses Fiddle's `execve` binding because Ruby's `spawn`/`exec` can implicitly retry executable text through `/bin/sh`. On `ENOEXEC`, it rejects binary-looking prefixes and re-execs the current Ruby with a trusted native-runner bootstrap, preserving descriptors, environment, standalone PID replacement, and hosted process-group ownership. Never retry permission failures or delegate unsupported syntax to another shell; keep Ruby startup environment hooks disabled for that internal bootstrap. Prefer POSIX semantics wherever compatible with explicit host lifecycle guarantees. Preserve the private socket/PTY separation, direct argv/environment execution, cancellation, and tab detachment. `kwsh <file> [args]` runs a native script in an isolated child interpreter; declarative rc `source` remains non-executing. Prompt conveniences are not scripting builtins. The one-off `!command`, `/capture`, and normal model/RPC shell workers keep their existing paths and sandbox policy; persistent native shell sessions are explicitly TUI-only in RPC capabilities; standalone `kwsh` remains an ordinary external program subject to existing tool sandbox policy. Update `doc/shell.md` and the scoped shell-agent prompt when changing the subset.

## Feature exposure rule

Any user-visible Kward feature must be exposed consistently across supported frontends. When adding or changing a feature, update the CLI/TUI path, RPC API, initialize capabilities, docs, and tests as applicable. If a feature is intentionally not exposed through RPC, document the reason and make the capability report explicit unsupported status.
