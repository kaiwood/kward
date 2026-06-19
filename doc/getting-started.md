# Getting started

Use Kward when you want an agent in your terminal that can inspect the current project, explain code, edit files, run local commands, and keep an interactive session history.

This page gets you from install to a first useful chat.

## Requirements

- Ruby 3.2 or newer.
- Credentials for one model provider. The easiest setup is `kward login` or `/login` inside Kward.
- Bundler only if you run Kward from a source checkout.

## Install

Install the gem:

```bash
gem install kward
```

Install the starter pack:

```bash
kward init
```

The starter pack adds default prompts and a base `PRINCIPLES.md` under `~/.kward`. It does not overwrite existing files.

If you are working from a checkout instead:

```bash
bundle install
ruby lib/main.rb init
```

## Sign in

From your shell:

```bash
kward login
```

Or from inside an interactive session:

```text
/login
```

Kward supports OpenAI/ChatGPT, Anthropic Claude Pro/Max, OpenRouter, and experimental Copilot credentials. See [Authentication](authentication.md) when you need a specific provider.

## Start an interactive chat

Run Kward from the project you want it to work on:

```bash
cd ~/code/my-project
kward
```

Ask something concrete:

```text
Explain the structure of this project.
```

Then try a task that uses the workspace:

```text
Find where user authentication is implemented and summarize the flow.
```

Kward can read files, suggest edits, apply changes, and run commands from the workspace. Existing files must be read in the current conversation before Kward can edit them.

## Ask one question and exit

For quick tasks, pass the prompt directly:

```bash
kward "Explain this project"
```

Review a diff:

```bash
git diff | kward "Review this diff for bugs"
```

One-shot prompts do not use Kward memory.

## Useful first commands

Inside interactive Kward:

```text
/login              sign in or save provider credentials
/model              choose a model
/status             show session and context status
/sessions           open the saved sessions picker
/resume             alias for /sessions
/rewind             revisit an earlier prompt
/export notes.md    export the transcript
/compact            summarize older context when a chat gets long
/exit               leave Kward
```

## Run from source

```bash
ruby lib/main.rb login
ruby lib/main.rb
ruby lib/main.rb "Explain this project"
```

You can also run:

```bash
exe/kward
```

## Next steps

- Read [Usage](usage.md) for day-to-day workflows.
- Read [Configuration](configuration.md) when you want to change providers, models, memory, or web search.
- Read [Extensibility](extensibility.md) when you want reusable prompts, skills, or project rules.
