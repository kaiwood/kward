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

Optionally install the starter pack:

```bash
kward init
```

The starter pack adds default prompts and a base `PRINCIPLES.md` under `~/.kward`. It does not overwrite existing files. It is safe to skip if you prefer to create your own instructions. It requires network access because it fetches the pack from GitHub.

Verify your setup:

```bash
kward doctor
```

This checks your config, auth, writable directories, and workspace. Run `kward help` to see all available commands and examples.

Interactive startup also performs a cached RubyGems version check by default. It does not contact RubyGems on every start; disable it with `KWARD_DISABLE_UPDATE_CHECK=1` or the `updates.check` configuration setting. See [Configuration](configuration.md#Update_checks).

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

Confirm your credentials are saved:

```bash
kward auth status
```

If your provider offers multiple models, choose one inside Kward with `/model`.

## Start an interactive chat

Run Kward from the project you want it to work on:

```bash
cd ~/code/my-project
kward
```

Or point Kward at a project without leaving your shell:

```bash
kward --working-directory ~/code/my-project
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

## Useful interactive commands

Inside interactive Kward:

```text
/login              sign in or save provider credentials
/model              choose a model
/status             show session and context status
/session           open the saved sessions picker
/rewind             revisit an earlier prompt
/export notes.md    export the transcript
/compact            summarize older context when a chat gets long
/exit               leave Kward
```

## Next steps

- Read [Usage](usage.md) for day-to-day workflows.
- Read [Configuration](configuration.md) when you want to change providers, models, memory, or web search.
- Read [Security and trust](security.md) before using Kward with sensitive data, untrusted repositories, or third-party extensions.
- Read [Extensibility](extensibility.md) when you want reusable prompts, skills, or project rules.
