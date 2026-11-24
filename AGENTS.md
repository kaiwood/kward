# AGENTS.md

Kward is an extensible Ruby coding agent with a CLI/TUI and a JSON-RPC backend. Most code lives in `lib/kward/`; Minitest tests live in `test/`.

## Working in this repo

- Keep changes focused. Follow existing Ruby patterns and prefer the standard library over new dependencies. Use canonical internal require paths and preserve public entrypoints.
- Add focused tests for behavior changes. Stub external services rather than calling live providers. Keep secrets and private user data out of logs and fixtures.
- For user-visible changes, check CLI/TUI, RPC capabilities, and other affected frontends. Document intentional frontend limitations and report unsupported RPC capabilities explicitly.
- Update affected docs and add user-facing changes under `[Unreleased]` in `CHANGELOG.md`, grouped by Added, Changed, Fixed, or Removed.

## Commands

```bash
bundle install
ruby -Itest test/test_cli.rb  # Run one test file
ruby -Itest -e 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'  # Run all tests
ruby lib/main.rb  # Run the CLI locally
```

## Where to look

- [Contributing](CONTRIBUTING.md), [security policy](SECURITY.md), and [release workflow](doc/releasing.md).
- [RPC](doc/rpc.md), [plugins](doc/plugins.md), [skills](doc/skills.md), and [configuration](doc/configuration.md).
- [Shell behavior and limits](doc/shell.md), [POSIX roadmap](plan/PLAN.md), and [requirement matrix](plan/POSIX_REQUIREMENTS.md). Native `kwsh` must not fall back to another shell or parse expanded data as commands. Keep hosted process ownership separate from standalone behavior.
- Session JSONL in `lib/kward/sessions/store.rb` is authoritative; the catalog is a rebuildable cache.
