# Getting started

Kward is a Ruby CLI coding agent for local projects. It can answer questions, inspect files, propose and apply edits, run confirmed commands, search the web, and keep session history.

This page gets you to a first working chat. For day-to-day features after that, see [Usage](usage.md).

## Requirements

- Ruby 3.2 or newer.
- Bundler when running from source.
- Provider credentials for at least one model backend:
  - OpenAI/ChatGPT OAuth credentials, or
  - an OpenRouter API key, or
  - a GitHub token/OAuth setup for experimental Copilot provider support.

## Install

Kward is being prepared for a RubyGems release. Once published:

```bash
gem install kward
```

Until then, run it from a repository checkout:

```bash
bundle install
```

## Choose a provider

Kward defaults to the OpenAI/ChatGPT Codex backend when OpenAI credentials are available. OpenRouter is the easiest API-key option.

### OpenAI OAuth

Add an OAuth client ID to `~/.kward/config.json`:

```json
{
  "openai_oauth_client_id": "your-client-id"
}
```

Then log in:

```bash
kward login
```

From source, use:

```bash
ruby lib/main.rb login
```

### OpenRouter API key

To save an OpenRouter API key:

```bash
kward login openrouter
```

From source, use:

```bash
ruby lib/main.rb login openrouter
```

For all authentication options and fallback rules, see [Authentication](authentication.md).

## Start chatting

Interactive mode starts a saved multi-turn session:

```bash
kward
```

From source:

```bash
ruby lib/main.rb
```

Ask a one-shot question and exit:

```bash
kward "Explain this project"
```

From source:

```bash
ruby lib/main.rb "Explain this project"
```

You can also pipe input:

```bash
cat README.md | kward
```

## Useful first commands

Inside an interactive session:

```text
/status              show current session and compaction status
/model               choose the default model
/reasoning           choose reasoning effort
/resume              resume a saved session
/export notes.md     export the current session as Markdown
/exit                leave the session
```

Kward saves interactive sessions under `~/.kward/sessions/`.

## Safety basics

- Kward must read an existing file in the current conversation before it can edit or overwrite it.
- File writes and edits ask for confirmation first.
- Shell commands ask for confirmation before running.
- Tool reads are bounded so large files are not accidentally loaded into context.

## Run tests

If you are developing Kward itself:

```bash
bundle exec rake test
```

Equivalent direct command:

```bash
ruby -Itest -e 'Dir["test/**/test_*.rb"].sort.each { |file| require_relative file }'
```
