# Plugins

Plugins are trusted local Ruby extensions for Kward. Use them when you need behavior that prompts, skills, or instructions cannot provide.

Good plugin use cases:

- add a slash command for a personal workflow,
- show project/session status in the terminal footer,
- add concise local context to prompts,
- log or observe transcript events,
- expose local commands to an RPC client.

Plugins run inside the Kward process with your user permissions. Install only plugins you trust.

## When to use a plugin

| Need | Better choice |
| --- | --- |
| Reusable prompt text | prompt template |
| Reusable model instructions | skill |
| Repository rules | `AGENTS.md` |
| Local Ruby code or integration | plugin |

## Where plugins live

Kward loads top-level Ruby files from:

```text
~/.kward/plugins/*.rb
```

Plugins are not loaded from the current workspace or a custom `KWARD_CONFIG_PATH` directory. This prevents a project checkout from silently adding executable Ruby code to Kward.

## A first plugin

Create the plugin directory:

```bash
mkdir -p ~/.kward/plugins
```

Create `~/.kward/plugins/hello.rb`:

```ruby
Kward.plugin do |plugin|
  plugin.command "hello", description: "Say hello", argument_hint: "[name]" do |args, ctx|
    name = args.strip.empty? ? "there" : args.strip
    ctx.say("Hello, #{name}.")
  end
end
```

Start Kward and run:

```text
/hello Kai
```

## Add a slash command

Use plugin commands for local actions that should not call the model.

```ruby
Kward.plugin do |plugin|
  plugin.command "session-info", description: "Show session details" do |_args, ctx|
    ctx.say("Session: #{ctx.session_name || ctx.session_id || 'unnamed'}")
    ctx.say("Workspace: #{ctx.workspace_root}")
  end
end
```

Command names do not include `/`. They must start with a letter or number and may contain letters, numbers, `_`, and `-`.

A plugin command cannot replace a built-in command or prompt-template command.

## Add prompt context

Prompt context is short text injected into future model requests.

Use it for stable facts the model should know, not for large files or secrets.

```ruby
Kward.plugin do |plugin|
  plugin.prompt_context do |ctx|
    next unless File.exist?(File.join(ctx.workspace_root, "Gemfile"))

    "Workspace note: this project uses Ruby. Prefer bundle exec for project commands."
  end
end
```

If plugin state changes and Kward should rebuild the active system message, call:

```ruby
ctx.refresh_system_message!
```

## Add a footer

A footer can show compact local status in the terminal UI:

```ruby
Kward.plugin do |plugin|
  plugin.footer do |ctx|
    "#{ctx.session_name || 'unnamed'} • #{ctx.transcript.messages.length} messages"
  end
end
```

Only one footer is active. If multiple plugins register footers, the later one replaces the earlier one and Kward prints a warning.

## Observe transcript events

Use transcript events when you need to log or react to live activity:

```ruby
Kward.plugin do |plugin|
  plugin.on_transcript_event do |event, ctx|
    next unless event.type == "assistant_delta"

    File.open(File.join(ctx.workspace_root, ".assistant-stream.log"), "a") do |file|
      file.write(event.payload[:delta])
    end
  end
end
```

Event payloads are read-only copies. Handler errors are caught and printed as warnings.

Common event types include:

- `reasoning_delta`
- `assistant_delta`
- `assistant_message`
- `model_retry`
- `turn_steered`
- `tool_call`
- `tool_result`
- `answer`

## Plugin context

Handlers receive a `ctx` object. Common methods:

- `ctx.workspace_root`
- `ctx.args`
- `ctx.say(message)`
- `ctx.transcript.messages`
- `ctx.session_id`
- `ctx.session_name`
- `ctx.session_path`
- `ctx.refresh_system_message!`

The transcript is read-only. Use context methods instead of mutating Kward internals.

## RPC support

Plugins are available in the CLI and experimental RPC backend.

RPC clients can:

- list plugin commands through `commands/list`,
- run plugin commands through `commands/run`,
- run plugin slash commands through `turns/start` input such as `/hello Kai`.

Plugin command output is emitted through normal turn events without calling the model.

## Security

Plugins are local Ruby code. They can read files, write files, run commands, make network requests, and read environment variables as your user.

Recommended practices:

- Install plugins only from sources you trust.
- Keep plugins in your personal `~/.kward/plugins` directory.
- Do not put secrets in shared plugin files.
- Prefer environment variables or private config for credentials.
- Keep prompt context short and never inject secrets into model prompts.
- Be careful with transcript observers that persist conversation content.
