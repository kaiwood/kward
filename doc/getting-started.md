# Getting started

Ruby CLI Agent is a minimal CLI coding agent using OpenRouter or OpenAI.

## Install

```bash
bundle install
```

## Basic commands

```bash
ruby lib/main.rb login                    # sign in with OpenAI OAuth
ruby lib/main.rb                          # start a multi-turn chat
ruby lib/main.rb "Explain this Ruby file" # single prompt
```

## Run tests

```bash
ruby -Itest -e 'Dir["test/test_*.rb"].sort.each { |file| require_relative file }'
```

For day-to-day interaction details, see [Usage](usage.md).
