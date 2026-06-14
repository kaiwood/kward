# Kward

Kward is an extendable Ruby CLI coding agent. It can chat with you about a project, inspect and edit files, run confirmed shell commands, search the web, look up public source code, save local sessions, and load trusted Ruby plugins for custom workflows.

It currently supports the OpenAI/ChatGPT Codex backend, Anthropic Claude Pro/Max subscription, OpenRouter, and experimental Copilot provider support.

## Install

Install Kward from RubyGems:

```bash
gem install kward
```

Optionally install the starter pack after installation:

```bash
kward init
```

This downloads Kward's default prompts and base `AGENTS.md` into your config directory. It is useful for a first setup, but safe to skip if you prefer to create your own instructions. Existing files are left untouched.

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

## Run from source

If you are working from a checkout:

```bash
bundle install
ruby lib/main.rb login                    # sign in or save provider credentials
ruby lib/main.rb                          # start an interactive chat
ruby lib/main.rb help                     # show available commands and examples
ruby lib/main.rb "Explain this project"   # run one prompt and exit
```

You can also use the executable directly after installing dependencies:

```bash
exe/kward
```

## What Kward can do

- Keep a multi-turn coding conversation in your terminal.
- Read, write, and edit workspace files with read-before-write guardrails.
- Run local shell commands from the workspace.
- Search the live web and inspect cached public GitHub repositories.
- Save, resume, clone, compact, and export sessions.
- Extend the Agent with trusted Ruby plugins for custom commands, footer UI, prompt context, and transcript-event observers.
- Use optional memory, personas, prompt templates, and skills.
- Serve an experimental JSON-RPC backend for UI clients.

## Documentation

Start here:

- [Getting started](doc/getting-started.md): first run, authentication choices, and basic commands.
- [Usage](doc/usage.md): interactive chat, slash commands, sessions, tools, images, and Pan mode.
- [Configuration](doc/configuration.md): config files, providers, models, web search, logging, and color output.
- [Authentication](doc/authentication.md): OpenAI OAuth, Anthropic OAuth, OpenRouter API keys, and Copilot/GitHub setup.
- [Troubleshooting](doc/troubleshooting.md): environment-specific install and runtime issues.

Feature guides:

- [Memory](doc/memory.md): opt-in core, soft, and session memory.
- [Extensibility](doc/extensibility.md): `AGENTS.md`, personas, skills, and prompt templates.
- [Plugins](doc/plugins.md): trusted Ruby plugins for commands, footer UI, prompt context, transcript events, and RPC clients.
- [Web search](doc/web-search.md): live search providers and network behavior.
- [Code search](doc/code-search.md): package lookup, GitHub repository cache, and external source reading.

Advanced/reference:

- [RPC protocol](doc/rpc.md): experimental JSON-RPC backend mode for UI clients.
- [Releasing](doc/releasing.md): release checklist for RubyGems publishing.

## Run tests

```bash
bundle exec rake test
```

Equivalent direct command:

```bash
ruby -Itest -e 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
```

## Generate API documentation

```bash
bundle exec rake rdoc
bundle exec yard doc
```
