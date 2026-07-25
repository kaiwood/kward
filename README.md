# Kward

Kward is a personal developer workspace that lives in your terminal. It brings together persistent conversations, project-aware tools, local automation, and trusted integrations so you can understand a codebase, make changes, investigate problems, and carry work forward across sessions.

Use Kward from the terminal, a local browser interface, or a trusted JSON-RPC client. It can work with your files and Git state, run local commands, research external sources, manage session history, and adapt to your workflows through project instructions, skills, memory, personas, hooks, plugins, MCP servers, and transports.

Kward supports the OpenAI/ChatGPT Codex backend, Anthropic Claude Pro/Max subscriptions, OpenRouter, Copilot, and OpenAI-compatible local servers such as Ollama, LM Studio, and llama.cpp.

## Why use Kward?

Kward is for development work that has context, history, and consequences—not isolated one-off prompts.

It gives you one place to:

- Explore an unfamiliar project and preserve what you learned.
- Investigate bugs, review changes, and run focused local checks.
- Make and verify edits with workspace boundaries, read-before-edit guardrails, optional approvals, and command sandboxing.
- Split work across sessions, branches, tabs, and linked Git worktrees.
- Carry your own working conventions through `PRINCIPLES.md`, `AGENTS.md`, skills, prompt templates, and optional memory.
- Extend trusted local workflows with plugins, lifecycle hooks, MCP servers, external transports, and JSON-RPC clients.

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

Then sign in and start Kward:

```bash
kward login                    # sign in or save provider credentials
kward                          # start an interactive chat
kward help                     # show available commands and examples
kward hooks doctor             # inspect lifecycle hook setup
kward "Explain this project"   # run one prompt and exit
kward --working-directory ~/code/project "Explain this project"
```

From inside Kward, `/login` opens the same provider picker.

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

New to Kward:

- [Getting started](doc/getting-started.md): first run, authentication choices, and basic commands.
- [Usage](doc/usage.md): interactive chat, slash commands, sessions, tools, images, and Pan mode.
- [Configuration](doc/configuration.md): config files, providers, models, web search, logging, and color output.
- [Authentication](doc/authentication.md): OpenAI OAuth, Anthropic OAuth, OpenRouter API keys, and Copilot/GitHub setup.

Work safely:

- [Security and trust](doc/security.md): local permissions, external data flow, trusted extensions, and safe work in unfamiliar repositories.
- [Permissions](doc/permissions.md): opt-in tool approval, write scopes, policy rules, and current limits.
- [Command sandboxing](doc/sandboxing.md): opt-in OS-enforced boundaries for model-requested shell commands.
- [Troubleshooting](doc/troubleshooting.md): environment-specific install and runtime issues.

Everyday workflows:

- [Sessions](doc/session-management.md): resume, clone, fork, rewind, compact, and navigate saved work.
- [Interactive composer](doc/composer.md): use multiline input, completion, history, files, reasoning shortcuts, busy input, and images.
- [Tabs](doc/tabs.md): keep several conversations open and run work in another tab.
- [Project files](doc/files.md): browse, search, mention, open, and edit workspace files.
- [Integrated Editor](doc/editor.md): open files from the shell or composer, edit in-place, and choose editor keybindings.
- [Git](doc/git.md): review changes, use the diff viewer, stage files, and commit from the interactive TUI.
- [Shell](doc/shell.md): use `/shell`, the embedded Kward shell with aliases, completion, and per-tab state.
- [Memory](doc/memory.md): opt-in core, soft, and session memory.
- [Personas](doc/personas.md): configure Kward's tone and role by default, workspace, model, reasoning effort, time, and weekday.
- [Skills](doc/skills.md): add reusable instructions that load only for matching tasks.
- [Prompt templates](doc/prompt-templates.md): create reusable slash prompts and use the starter templates installed by `kward init`.
- [MCP servers](doc/mcp.md): connect trusted local Model Context Protocol tool servers.
- [Pan mode](doc/pan.md): use the mobile-friendly browser interface on a trusted local network.
- [Local models](doc/local-models.md): connect Ollama, LM Studio, or llama.cpp and use a minimal replacement prompt.

Extend and integrate:

- [Extensibility](doc/extensibility.md): choose between `PRINCIPLES.md`, workspace `AGENTS.md`, skills, prompt templates, and other extension points.
- [Plugins](doc/plugins.md): trusted Ruby plugins for commands, footer UI, prompt context, transcript events, and RPC clients.
- [Lifecycle hooks](doc/lifecycle-hooks.md): deterministic runtime hooks for policy, approvals, automation, and command-hook integrations.
- [RPC protocol](doc/rpc.md): JSON-RPC backend mode for trusted local UI clients.
- [Releasing](doc/releasing.md): release checklist for RubyGems publishing.

Reference guides:

- [Agent tools](doc/agent-tools.md): overview of model-callable tools, token-saving behavior, and tool categories.
- [Workspace tools](doc/workspace-tools.md): local file, edit, and shell command tools.
- [Context budgeting](doc/context-budgeting.md): focused context gathering, budgeted reads, output compaction, and token-saving history.
- [Web search](doc/web-search.md): live search providers and network behavior for the web search agent tool.
- [Code search](doc/code-search.md): package lookup, GitHub repository cache, and external source reading for the code search agent tool.
- [Context tools](doc/context-tools.md): skills, compacted output retrieval, and structured clarification questions.

Generated Ruby API:

- [API reference](doc/api.md): generated Ruby API entry points, indexes, and supported API expectations.

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
