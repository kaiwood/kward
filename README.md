# Kward

Kward is a small Ruby CLI coding agent. It can chat with you about a project, inspect and edit files, run confirmed shell commands, search the web, look up public source code, and save local sessions.

It currently supports the OpenAI/ChatGPT Codex backend, OpenRouter, and experimental Copilot provider support.

## Install

Kward is being prepared for a RubyGems release. Once published, install it with:

```bash
gem install kward
```

Then start with one of these commands:

```bash
kward login                    # sign in or save provider credentials
kward                          # start an interactive chat
kward "Explain this project"   # run one prompt and exit
```

OpenAI OAuth requires an `openai_oauth_client_id` in your config first. If you prefer OpenRouter, use `kward login openrouter` and paste an API key. See [Authentication](doc/authentication.md) for the details.

## Run from source

If you are working from a checkout:

```bash
bundle install
ruby lib/main.rb login                    # sign in or save provider credentials
ruby lib/main.rb                          # start an interactive chat
ruby lib/main.rb "Explain this project"   # run one prompt and exit
```

You can also use the executable directly after installing dependencies:

```bash
exe/kward
```

## What Kward can do

- Keep a multi-turn coding conversation in your terminal.
- Read, write, and edit workspace files with confirmation before changes.
- Run shell commands after confirmation.
- Search the live web and inspect cached public GitHub repositories.
- Save, resume, clone, compact, and export sessions.
- Use optional memory, personas, prompt templates, skills, and trusted local plugins.
- Serve an experimental JSON-RPC backend for UI clients.

## Documentation

Start here:

- [Getting started](doc/getting-started.md): first run, authentication choices, and basic commands.
- [Usage](doc/usage.md): interactive chat, slash commands, sessions, tools, images, and Pan mode.
- [Configuration](doc/configuration.md): config files, providers, models, web search, logging, and color output.
- [Authentication](doc/authentication.md): OpenAI OAuth, OpenRouter API keys, and Copilot/GitHub setup.

Feature guides:

- [Memory](doc/memory.md): opt-in core, soft, and session memory.
- [Extensibility](doc/extensibility.md): `AGENTS.md`, personas, skills, prompt templates, and plugins.
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
