# Ruby CLI Agent

Minimal CLI coding agent using OpenRouter or OpenAI.

## Quick start

```bash
bundle install
ruby lib/main.rb login                    # sign in with OpenAI OAuth
ruby lib/main.rb                          # start a multi-turn chat
ruby lib/main.rb "Explain this Ruby file" # single prompt
```

## Documentation

- [Getting started](doc/getting-started.md): installation, basic commands, and test command.
- [Usage](doc/usage.md): chat mode, tools, sessions, composer keys, and image attachments.
- [Authentication](doc/authentication.md): OpenAI OAuth and API key fallback behavior.
- [Configuration](doc/configuration.md): config files, models, environment variables, and color output.
- [Extensibility](doc/extensibility.md): `AGENTS.md`, skills, and prompt templates.
- [Web search](doc/web-search.md): search providers and network behavior.
- [RPC protocol](doc/rpc.md): experimental JSON-RPC backend mode for UI clients.

## Run tests

```bash
ruby -Itest -e 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
```
