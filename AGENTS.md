# AGENTS.md

Guidance for AI coding agents working in this repository.

This is a living document. If significant changes to the codebase, architecture, commands, workflows, or project conventions occur, update this file so future agents start with accurate guidance.

## Project overview

Kward is an extendable Ruby CLI coding agent. It supports interactive and one-shot chat, local workspace tools, configurable prompts/skills, image attachments, web search, OpenAI OAuth/API-key authentication, session persistence, and a JSON-RPC backend for UI clients.

## Working style

- Make the smallest correct change for the request.
- Inspect relevant files before editing, and preserve existing style and naming.
- Prefer straightforward Ruby from the standard library unless an existing dependency is already used.
- Internal requires should target canonical implementations under domain folders; root-level compatibility require files are only for legacy external paths.
- Keep user-facing behavior consistent with existing docs and tests.
- Do not introduce broad rewrites, formatting-only churn, or unrelated cleanup.
- Do not split large orchestration files such as `RPC::SessionManager` or `Model::Client` just because they are large; extract only when a behavior change exposes a clear, tested ownership boundary.
- Be careful with auth tokens, API keys, config files, session data, user prompts, and workspace file contents. Do not log secrets.

## Important paths

- `lib/main.rb` - executable entrypoint.
- `lib/kward/cli.rb` - command-line flow and interactive chat orchestration.
- `lib/kward/sessions/store.rb` - authoritative JSONL session persistence and conversation reconstruction.
- `lib/kward/sessions/catalog.rb` - rebuildable, fingerprint-validated session-list summary cache; JSONL sessions remain authoritative.
- `lib/kward/tabs/driver.rb` - session and plugin tab-driver boundary used by interactive tabs.
- `lib/kward/plugins/registry.rb` and `lib/kward/plugins/chat_runtime.rb` - trusted plugin registration and frontend-neutral plugin-chat execution.
- `lib/kward/git_worktree_manager.rb` - Git worktree discovery, creation, validation, and removal mechanics.
- `lib/kward/cli/worktrees.rb` - interactive session-tab worktree binding and workspace re-rooting orchestration.
- `lib/kward/shell/kwsh.rb`, `lib/kward/shell/kwshrc.rb`, and `lib/kward/shell/persistent_session.rb` - embedded-shell command routing, declarative rc parsing, state, protocol, and PTY lifecycle.
- `lib/kward/pty/detached_run.rb` - shared lifecycle for commands detached from terminal ownership while remaining owned by a tab.
- `lib/kward/shell/prompt.rb` and `lib/kward/shell/prompt_session.rb` - transient shell-agent prompt context and scoped actions.
- `lib/kward/agent.rb` - agent loop and tool execution flow.
- `lib/kward/model/` - model provider HTTP client and stream parsing behavior.
- `lib/kward/auth/` - OAuth providers and auth credential file helpers.
- `lib/kward/tools/registry.rb` - tool dispatch and schema exposure.
- `lib/kward/tools/` - individual tool implementations, one file per tool.
- `lib/kward/mcp/` - local MCP client transports and configured server clients.
- `lib/kward/transport.rb` and `lib/kward/transport/` - frontend-neutral transport contracts, host, session gateway, persistent state, lifecycle manager, and foreground runtime.
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

- This project uses Minitest. Add or update focused tests for behavior changes.
- Network/auth behavior should be easy to test without real external calls; follow existing test patterns and stubs.
- Keep CLI output stable unless the task is explicitly about UX copy.
- Keep documentation current when behavior, configuration, extension points, commands, tools, RPC capabilities, or generated docs navigation changes.
- Add user-facing changes to the `CHANGELOG.md` `[Unreleased]` section using grouped `### Added`, `### Changed`, `### Fixed`, or `### Removed` subsections.
- When adding configuration, document default behavior and environment variable interactions.
- When adding tools, keep tool schemas, argument validation, execution, and tests aligned.
- When changing prompt/skill behavior, update `doc/extensibility.md`, `doc/skills.md`, CLI/RPC/Pan exposure, compaction behavior when activated instructions are durable, and prompt-related tests as needed. Skill capture sends the complete selected persisted session branch to the active model provider, must stay personal-skill-only, and requires editable review before an explicit save.
- Keep terminal text ownership centralized: `TerminalSequences` owns terminal output/control sequences, `TerminalKeys` owns input key byte sequences and key parser regexes, `ANSI` owns styling plus escape-aware transcript stripping/sanitizing/wrapping, `TerminalText` owns Unicode cell widths and grapheme-aware composer layout, and `PromptInterface::KeyHandler` owns input reading, tokenization, queueing, parsing, and dispatch mechanics.
- Vibe `:prompt <instruction>` and Modern `Ctrl+.` prompt lines run an interactive, editor-scoped agent turn. The model receives the active in-memory buffer and can use only the transactional `replace_editor_buffer` tool; commit generated content back to the editor as one undoable change and leave disk persistence to the user's normal save command. Keep this TUI-only until an equivalent editor capability exists for other frontends.
- Editor runners execute the current in-memory buffer for scratchpads and normal editable files. Keep runner binaries configured under `editor.runners`, resolve relative binaries from the active workspace, invoke them directly without a shell, and preserve bounded capture plus cancellation. JavaScript and TypeScript use Node by default; compiler-backed languages need explicit runner mechanics before becoming runnable.
- Inline image capability detection should prefer an active Kitty graphics probe on real TTYs, use recognized terminal hints when probing is inconclusive, retry transient detection failures, and fail closed for unknown terminals. Keep Kitty payloads protocol-valid, chunked, and response-suppressed so terminal acknowledgements do not enter the composer, and keep protocol-specific encoding in `TerminalSequences`.
- User-entered external `/shell` commands and `!command` use adaptive interactive PTY handoff by default: conservative line/progress controls and synchronized-output brackets render above a frozen composer, while screen-oriented or unknown controls trigger permanent full-terminal passthrough for that command. Keep the output classifier byte-preserving and incremental across chunks, close unterminated synchronized output before handback or exclusive transition, suppress Kward rendering throughout child ownership, and retain at most bounded transcript-safe output captured before the first forwarded input byte. Normalize carriage-return and horizontal-cursor progress to its final visible line for transient reconstruction. Tab shortcuts detach running shell commands into their originating tab's bounded background state rather than cancelling them; only explicit cancellation or shutdown terminates detached work. `/shell` owns a persistent local shell session; `capture <command>` retains bounded, sanitized output, while `/capture <command>` provides bounded one-shot transcript output. A leading `?` inside `/shell` runs a transient per-tab shell-agent turn; pass only bounded, sanitized last-command context, route explicit execution through the active shell session, and use `prepare_shell_command` for drafts that must remain unexecuted until the user presses Enter. Keep ordinary model-requested and RPC `run_shell_command` workers captured, cancellable, sandbox-aware, and noninteractive; the explicit `?` shell prompt is the user-directed exception that runs through the host-owned shell session. SSH remains a terminal-owned follow-up boundary rather than a shell-agent session.
- Plugin-owned tabs register through `plugin.tab_type`, open through `/tab open <name>`, and own their storage and turn behavior. Keep their drivers independent of workspace sessions, agents, prompts, and tools; the interactive tab host owns composer, rendering, streaming, cancellation, and layouts. Plugin tabs opt into RPC explicitly with `rpc: true`; they opt into external targeting separately with `transport: true`. `PluginChatRuntime` owns shared scoped turn queues, actor context, events, attachments, replay, and cancellation; RPC and transport adapters remain frontend facades without creating workspace sessions.
- External transports register through `plugin.transport`, use `Transport::Host` for normal Kward sessions or explicitly transport-capable plugin chats, persist namespaced state under the config directory, and implement explicit `start`/`stop` lifecycle methods. Transport plugins are trusted local code; remote identities still require host policy checks. Plugin-chat drivers may receive authenticated actor context but must enforce scope and ownership in trusted code. Execution profiles enforce generic session restrictions; plugin-owned tools and memory require their own explicit policy. Isolated transports should use a dedicated process/config root for strong separation.
- Normal session tabs may persist a Git worktree binding in their tab descriptor. Active worktree tabs rebuild their conversation and agent against the linked root, force workspace guardrails and strict model-command sandboxing, and keep MCP clients and lifecycle hooks disabled for that strict agent. RPC reports worktree bindings as interactive-TUI-only until an equivalent session API exists.

## Feature exposure rule

Any user-visible Kward feature must be exposed consistently across supported frontends. When adding or changing a feature, update the CLI/TUI path, RPC API, initialize capabilities, docs, and tests as applicable. If a feature is intentionally not exposed through RPC, document the reason and make the capability report explicit unsupported status.
