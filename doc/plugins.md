# Plugins

Plugins are Kward's trusted local extension system. They let you add project or personal workflow features without changing Kward itself.

A plugin can:

- add interactive slash commands,
- expose commands through the RPC backend,
- render a custom terminal footer,
- inject concise prompt context into future model requests,
- observe live transcript events such as assistant output, tool calls, and retries.

Plugins are plain Ruby files. They run inside the Kward process with your local user permissions, so install only plugins you trust.

Use a prompt template when reusable text is enough. Use a skill when you need reusable instructions. Use a plugin when you need local Ruby behavior, file or network integration, custom commands, or transcript observers.

## Where plugins live

Kward loads top-level Ruby files from:

```text
~/.kward/plugins/*.rb
```

Plugins are intentionally **not** loaded from the current workspace, from a project repository, or from a custom `KWARD_CONFIG_PATH` directory. This keeps plugin loading tied to the local user account rather than to whatever project Kward is currently inspecting.

## A first plugin

Create the plugin directory:

```bash
mkdir -p ~/.kward/plugins
```

Then create `~/.kward/plugins/hello.rb`:

```ruby
Kward.plugin do |plugin|
  plugin.command "hello", description: "Say hello", argument_hint: "[name]" do |args, ctx|
    name = args.strip.empty? ? "captain" : args.strip
    ctx.say("Hello, #{name}.")
  end
end
```

Start Kward and run:

```text
/hello Kai
```

Plugin commands appear in interactive slash completion and in RPC command listings.

## Slash commands

Register a command with `plugin.command`:

```ruby
Kward.plugin do |plugin|
  plugin.command "session-info", description: "Show session details" do |_args, ctx|
    ctx.say("Session: #{ctx.session_name || ctx.session_id || 'unnamed'}")
    ctx.say("Path: #{ctx.session_path || 'not saved'}")
    ctx.say("Workspace: #{ctx.workspace_root}")
  end
end
```

Command names:

- do not include the leading `/`,
- must start with a letter or number,
- may contain letters, numbers, `_`, and `-`,
- cannot replace built-in commands or prompt-template commands.

If a plugin command conflicts with a reserved or duplicate command, Kward skips it and prints a warning.

Command handlers receive:

- `args`: the raw text after the command name,
- `ctx`: a plugin context object.

Use `ctx.say(message)` for user-visible output.

## Prompt context

Plugins can add concise context to future system prompts:

```ruby
Kward.plugin do |plugin|
  plugin.prompt_context do |ctx|
    next unless File.exist?(File.join(ctx.workspace_root, "Gemfile"))

    "Workspace note: this project uses Ruby. Prefer bundle exec for project commands."
  end
end
```

Prompt context is injected after personas and before skills/workspace instructions. Keep it short and stable. Long or noisy prompt context will be sent repeatedly to the model and can reduce useful context space.

If plugin state changes and the active conversation should rebuild its system message, call:

```ruby
ctx.refresh_system_message!
```

from a command or event handler.

## Custom footer

A plugin can render one custom footer for the terminal UI:

```ruby
Kward.plugin do |plugin|
  plugin.footer do |ctx|
    name = ctx.session_name || "unnamed"
    messages = ctx.transcript.messages.length
    "#{name} • #{messages} messages"
  end
end
```

Only one footer renderer is active. If multiple plugins register footers, the later one replaces the earlier one and Kward prints a warning.

Footer errors are caught and printed as warnings so they do not break the session.

## Transcript events

Plugins can observe live transcript stream events:

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

Supported event types include:

- `reasoning_delta`
- `assistant_delta`
- `assistant_message`
- `model_retry`
- `turn_steered`
- `tool_call`
- `tool_result`
- `answer`

Event payloads are deep-frozen copies. Treat them as read-only.

Transcript-event handler errors are caught and printed as warnings.

## Plugin context API

Plugin handlers receive a `ctx` object with:

- `ctx.args` - raw command arguments for contexts that have them.
- `ctx.workspace_root` - active workspace path.
- `ctx.transcript.messages` - deep-frozen copy of active conversation messages.
- `ctx.say(message)` - emit output to the active frontend when available.
- `ctx.session_id` - current persisted session ID when available.
- `ctx.session_name` - current session name when available.
- `ctx.session_path` - current session file path when available.
- `ctx.refresh_system_message!` - rebuild the active conversation system message.

The transcript is read-only by design. Plugins should use Kward APIs exposed through the context rather than mutating conversation internals.

## RPC support

Plugins are available to both the CLI and the experimental RPC backend.

RPC clients can:

- list plugin commands through `commands/list`,
- run plugin commands through `commands/run`,
- run plugin slash commands through `turns/start` input such as `/hello Kai`.

When a plugin command is run as a turn, Kward emits command output through normal turn events without calling the model.

## Security model

Plugins are trusted local Ruby code. A plugin can read and write files, run commands, make network requests, and access process environment variables just like any Ruby code running as your user.

Recommended practices:

- Install plugins only from sources you trust.
- Keep plugins in your personal `~/.kward/plugins` directory.
- Do not place secrets directly in plugin files if they will be shared.
- Prefer user-specific config or environment variables for credentials.
- Keep prompt context concise and avoid injecting secrets into model prompts.
- Be careful when writing transcript observers that persist conversation content.

## Complete example

```ruby
Kward.plugin do |plugin|
  plugin.command "last-message", description: "Show transcript size" do |_args, ctx|
    ctx.say("Messages: #{ctx.transcript.messages.length}")
  end

  plugin.footer do |ctx|
    "#{ctx.session_name || 'unnamed'} • #{ctx.transcript.messages.length} messages"
  end

  plugin.prompt_context do |_ctx|
    "Project background: prefer small, focused changes."
  end

  plugin.on_transcript_event do |event, ctx|
    next unless event.type == "assistant_delta"

    File.open(File.join(ctx.workspace_root, ".assistant-stream.log"), "a") do |file|
      file.write(event.payload[:delta])
    end
  end
end
```
