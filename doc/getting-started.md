# Getting started

Kward is a Ruby CLI coding agent for local projects. It can answer questions, inspect files, propose and apply edits, run confirmed commands, search the web, and keep session history.

This page gets you to a first working chat. For day-to-day features after that, see [Usage](usage.md).

## Requirements

- Ruby 3.2 or newer.
- Bundler when running from source.
- Credentials for at least one model provider. You can add them with `/login` inside Kward or with `kward login` from your shell.

## Install

Kward is being prepared for a RubyGems release. Once published:

```bash
gem install kward
```

Optionally install the starter pack:

```bash
kward --install-starter-pack
```

The starter pack adds useful default prompts and a base `AGENTS.md` to your config directory. It is helpful for a first setup, but safe to skip if you want to write your own instructions. Existing files are not overwritten.

Until the gem is published, run Kward from a repository checkout:

```bash
bundle install
ruby lib/main.rb --install-starter-pack   # optional
```

## Start Kward and sign in

Start an interactive session:

```bash
kward
```

From source:

```bash
ruby lib/main.rb
```

When Kward needs credentials, sign in from inside the session:

```text
/login
```

You can also sign in from your shell before starting a chat:

```bash
kward login
```

From source:

```bash
ruby lib/main.rb login
```

For provider-specific login options, such as OpenRouter API keys or experimental Copilot support, see [Authentication](authentication.md).

## Ask one question and exit

Pass a prompt as command-line text:

```bash
kward "Explain this project"
```

From source:

```bash
ruby lib/main.rb "Explain this project"
```

You can also pipe input:

```bash
git diff | kward "Review this diff"
```

One-shot prompts do not use Kward memory.

## Useful first commands

Inside an interactive session:

```text
/login              sign in or save provider credentials
/status             show current session and compaction status
/model              choose the default model
/reasoning          choose reasoning effort
/resume             resume a saved session
/export notes.md    export the current session as Markdown
/exit               leave the session
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
