# AGENTS.md

Guidance for AI coding agents working in this repository.

This is a living document. If significant changes to the codebase, architecture, commands, workflows, or project conventions occur, update this file so future agents start with accurate guidance.

## Project overview

Kward is an extendable Ruby CLI coding agent. It supports interactive and one-shot chat, local workspace tools, configurable prompts/skills, image attachments, web search, OpenAI OAuth/API-key authentication, session persistence, and an experimental JSON-RPC backend for UI clients.

## Working style

- Make the smallest correct change for the request.
- Inspect relevant files before editing, and preserve existing style and naming.
- Prefer straightforward Ruby from the standard library unless an existing dependency is already used.
- Keep user-facing behavior consistent with existing docs and tests.
- Do not introduce broad rewrites, formatting-only churn, or unrelated cleanup.
- Be careful with auth tokens, API keys, config files, session data, user prompts, and workspace file contents. Do not log secrets.

## Important paths

- `lib/main.rb` - executable entrypoint.
- `lib/kward/cli.rb` - command-line flow and interactive chat orchestration.
- `lib/kward/agent.rb` - agent loop and tool execution flow.
- `lib/kward/model/` - model provider HTTP client and stream parsing behavior.
- `lib/kward/auth/` - OAuth providers and auth credential file helpers.
- `lib/kward/tool_registry.rb` - tool dispatch and schema exposure.
- `lib/kward/tools/` - individual tool implementations, one file per tool.
- `lib/kward/rpc/` - experimental JSON-RPC backend.
- `lib/kward/prompts.rb` - system prompt and prompt/skill discovery.
- `lib/kward/config_files.rb` - config path handling.
- `test/` - Minitest coverage.
- `doc/` - user documentation and generated docs source pages.
- `doc/api.md` - curated API reference overview used as the API docs landing page.
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

## Implementation notes

- This project uses Minitest. Add or update focused tests for behavior changes.
- Network/auth behavior should be easy to test without real external calls; follow existing test patterns and stubs.
- Keep CLI output stable unless the task is explicitly about UX copy.
- Keep documentation current when behavior, configuration, extension points, commands, tools, RPC capabilities, or generated docs navigation changes.
- Add user-facing changes to the `CHANGELOG.md` `[Unreleased]` section using grouped `### Added`, `### Changed`, `### Fixed`, or `### Removed` subsections.
- When adding configuration, document default behavior and environment variable interactions.
- When adding tools, keep tool schemas, argument validation, execution, and tests aligned.
- When changing prompt/skill behavior, update `doc/extensibility.md` and prompt-related tests as needed.
- Keep terminal escape ownership centralized: `TerminalSequences` owns terminal output/control sequences, `TerminalKeys` owns input key byte sequences and key parser regexes, `ANSI` owns styling plus visible text stripping/sanitizing/wrapping, and `PromptInterface::KeyHandler` owns input reading, tokenization, queueing, parsing, and dispatch mechanics.

## Feature exposure rule

Any user-visible Kward feature must be exposed consistently across supported frontends. When adding or changing a feature, update the CLI/TUI path, RPC API, initialize capabilities, docs, and tests as applicable. If a feature is intentionally not exposed through RPC, document the reason and make the capability report explicit unsupported status.
