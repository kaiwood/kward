# Kward

Kward is an extendable Ruby CLI coding agent. It can chat with you about a project, inspect and edit files, run confirmed shell commands, search the web, look up public source code, save local sessions, and load trusted Ruby plugins for custom workflows.

It currently supports the OpenAI/ChatGPT Codex backend, Anthropic Claude Pro/Max subscription, OpenRouter, and experimental Copilot provider support.

## Why use Kward?

Kward is designed for working with real projects, not isolated prompts.

Typical workflows include:

- Understanding an unfamiliar codebase
- Investigating bugs
- Reviewing changes
- Refactoring code
- Automating repetitive development tasks
- Building custom agent workflows through plugins

Examples:

```bash
kward "Explain this project"
kward "Review this diff"
kward "Find performance problems in this codebase"
```

## Install

Install Kward from RubyGems:

```bash
gem install kward
```

Optionally install the starter pack after installation:

```bash
kward init
```

This downloads Kward's default prompts and base `PRINCIPLES.md` into your config directory. It is useful for a first setup, but safe to skip if you prefer to create your own instructions. Existing files are left untouched.

Then start Kward and sign in when needed:

```bash
kward                          # start an interactive chat
kward help                     # show available commands and examples
/login                         # from inside Kward: sign in or save provider credentials
kward login                    # from your shell: sign in or save provider credentials
kward "Explain this project"   # run one prompt and exit
kward --working-directory ~/code/project "Explain this project"
```

See [Authentication](doc/authentication.md) for more details about sign-in options and provider credentials.

## What Kward can do

- Keep a multi-turn coding conversation in your terminal.
- Read, write, and edit workspace files with read-before-write guardrails.
- Run local shell commands from the workspace.
- Search the live web and inspect cached public GitHub repositories.
- Save, resume, clone, compact, and export sessions.
- Extend the Agent with trusted Ruby plugins for custom commands, footer UI, prompt context, and transcript-event observers.
- Use optional memory, personas, prompt templates, and skills.
- Serve a JSON-RPC backend for trusted local UI clients.

## Documentation

Start here:

- [Getting started](doc/getting-started.md): first run, authentication choices, and basic commands.
- [Usage](doc/usage.md): interactive chat, slash commands, sessions, tools, images, and Pan mode.
- [Configuration](doc/configuration.md): config files, providers, models, web search, logging, and color output.
- [Authentication](doc/authentication.md): OpenAI OAuth, Anthropic OAuth, OpenRouter API keys, and Copilot/GitHub setup.
- [Troubleshooting](doc/troubleshooting.md): environment-specific install and runtime issues.

Feature guides:

- [Sessions](doc/session-management.md): resume, clone, fork, rewind, compact, and navigate saved work.
- [Integrated Editor](doc/editor.md): open files from the composer, edit in-place, and choose editor keybindings.
- [Git](doc/git.md): review changes, use the diff viewer, stage files, and commit from the interactive TUI.
- [Shell](doc/shell.md): use `/shell`, the embedded Kward shell with aliases, completion, and per-tab state.
- [Memory](doc/memory.md): opt-in core, soft, and session memory.
- [Personas](doc/personas.md): configure Kward's tone and role by default, workspace, model, reasoning effort, time, and weekday.

Advanced:

- [Extensibility](doc/extensibility.md): `PRINCIPLES.md`, workspace `AGENTS.md`, skills, prompt templates, and extension choices.
- [Plugins](doc/plugins.md): trusted Ruby plugins for commands, footer UI, prompt context, transcript events, and RPC clients.
- [Lifecycle hooks](doc/lifecycle-hooks.md): deterministic runtime hooks for policy, approvals, automation, and command-hook integrations.
- [RPC protocol](doc/rpc.md): JSON-RPC backend mode for trusted local UI clients.
- [Releasing](doc/releasing.md): release checklist for RubyGems publishing.
- [Agent tools](doc/agent-tools.md): overview of model-callable tools, token-saving behavior, and tool categories.
- [Workspace tools](doc/workspace-tools.md): local file, edit, and shell command tools.
- [Context budgeting](doc/context-budgeting.md): focused context gathering, budgeted reads, output compaction, and token-saving history.
- [Web search](doc/web-search.md): live search providers and network behavior for the web search agent tool.
- [Code search](doc/code-search.md): package lookup, GitHub repository cache, and external source reading for the code search agent tool.
- [Context tools](doc/context-tools.md): skills, compacted output retrieval, and structured clarification questions.

API reference:

- [API reference](doc/api.md): generated Ruby API entry points, indexes, and public API expectations.

## Development

Run tests:

```bash
bundle exec rake test
```

Preview the built YARD documentation site locally with automatic rebuilds:

```bash
bundle exec rake docs:serve
```

The preview builds `_yardoc/`, serves it with WEBrick using `Cache-Control: no-store`, and rebuilds in a fresh process when documentation sources, library code, or templates change. Generated HTML, images, CSS, and JavaScript match the published site. Open <http://localhost:8808/> and refresh your browser after rebuilds. Use `PORT=4000 bundle exec rake docs:serve` to choose another port.

Build the static YARD documentation site for publishing:

```bash
bundle exec rake docs:build
```

The generated site is written to `_yardoc/`. Pushes to `main` deploy that directory to GitHub Pages.

Check generated documentation links, images, and scripts:

```bash
bundle exec rake docs:check
```

External link checks are disabled by default for stable local runs. Enable them with `DOCS_CHECK_EXTERNAL=1 bundle exec rake docs:check`.

Generate the RDoc API documentation:

```bash
bundle exec rake rdoc
```
