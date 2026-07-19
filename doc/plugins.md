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

See [Extensibility](extensibility.md) for the full overview of Kward's extension points and prompt assembly order.

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
/hello World
```

When developing plugins or prompt templates, use `/reload` inside Kward to reload configured prompt files and all plugin files without restarting. This picks up prompt edits, changes to existing plugins, and new plugin registrations, then refreshes slash-command completion and rebuilds the system message.

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

Use it for stable facts the model should know, not for large files or secrets. The block should return a string (injected into the system prompt) or `nil` (skipped). The example below uses Ruby's `next` to return `nil` early when the condition does not match.

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

## Add an interactive command

Interactive commands take over the composer region with a Kward-driven render and
input loop. The plugin receives a controller object with a canvas API for
drawing colored cells and reading keys. This is useful for games, dashboards,
viewers, and similar full-region interactive experiences.

`interactive_command` accepts `description:` and `argument_hint:` keyword arguments, which appear in the slash command list and completion overlay just like regular plugin commands. `rows:` sets the fixed canvas height (minimum 1), and `fps:` sets the target frame rate (1–120, default 30).

```ruby
Kward.plugin do |plugin|
  plugin.interactive_command "demo", rows: 10, fps: 30, description: "Canvas demo" do |ui, ctx|
    x = 0
    ui.on_tick do |ui|
      ui.clear_frame
      ui.put(0, x, "X", :red)
      x = (x + 1) % ui.width
      key = ui.poll_key
      return :exit if key == :ctrl_c || key == "q"
    end
  end
end
```

Run it with `/demo` from the interactive TUI. The canvas renders inside the
composer area for the specified number of rows. The transcript above stays
intact.

### Controller API

The `ui` controller object passed to the handler block exposes:

| Method | Description |
| --- | --- |
| `put(row, col, char, *colors)` | Place a character at a zero-based position with optional ANSI color styles |
| `clear_frame` | Reset all canvas cells to blank |
| `render` | Mark the canvas as ready for Kward to draw |
| `poll_key` | Return the next pending key (non-blocking, nil if none) |
| `exit` | Request that the interactive loop exit |
| `on_tick { \|ui\| }` | Register a tick callback invoked each frame at the configured fps |
| `width` | Canvas width in terminal columns |
| `height` | Canvas height in terminal rows |
| `fps` | Target frame rate |

Keys are returned as symbols (`:left`, `:right`, `:up`, `:down`, `:return`,
`:backspace`, `:space`, `:pageup`, `:pagedown`) or raw strings for keys
without a named mapping. Ctrl+C always exits the loop immediately.

The tick callback runs at the configured frame rate (1–120 fps, default 30).
Returning `:exit` from the tick callback ends the loop, same as calling
`ui.exit`.

### Lifecycle

- The composer state is saved on entry and fully restored on exit (input text,
  cursor, and transcript viewport).
- Interactive mode is a distinct state from the busy-input spinner lifecycle —
  no spinner or busy chrome is shown.
- Ctrl+C, the plugin calling `exit`, or the tick callback returning `:exit`
  all exit cleanly and restore the prior composer state.
- Resize during interactive mode forces a clean exit and restore.

Interactive commands require the TUI prompt interface. They are not available
in piped/non-interactive mode or through RPC.

## Add a plugin-owned tab

A plugin can provide a persistent tab with Kward's normal composer, transcript
rendering, streaming, image input, cancellation, and tab switching. The plugin
owns its transcript, storage, model behavior, and any global state; it does not
need to use a Kward workspace session.

```ruby
Kward.plugin do |plugin|
  plugin.tab_type "example", id: "com.example.chat", title: "Example", singleton: :global do |host, descriptor|
    ExampleChat.new(client: host.client, descriptor: descriptor)
  end
end
```

Open it from interactive Kward:

```text
/tab open example
```

`id` is a stable persisted identifier: do not change it after release.
Use `singleton: :global` for one plugin-managed chat shared by all tab views.

Plugin tabs do not notify global transcript observers by default. Set
`transcript_events: true` only when the tab explicitly permits its streamed
content to be delivered to every installed `on_transcript_event` handler, such
as a local text-to-speech plugin:

```ruby
plugin.tab_type "example", id: "com.example.chat", transcript_events: true do |host, descriptor|
  ExampleChat.new(client: host.client, descriptor: descriptor)
end
```

The observer context exposes the plugin tab's `messages` through
`ctx.transcript.messages`; it has no workspace session. The tab driver returned by the block must provide:

- `messages` — renderable transcript messages;
- `submit(input, display_input:, cancellation:, steering:)` — a turn method
  that returns the final response and yields stream events;
- `descriptor` — the durable tab descriptor;
- `supports_steering?` and `assistant_label`.

A driver may optionally implement `handles_command?(input)` and
`handle_command(input)` for its own slash commands. Other Kward session and
workspace commands stay unavailable inside plugin tabs.

Set `rpc: true` when the plugin tab can also be exposed as a trusted local RPC chat:

```ruby
plugin.tab_type "example", id: "com.example.chat", rpc: true do |host, descriptor|
  ExampleChat.new(client: host.client, descriptor: descriptor)
end
```

RPC clients discover opted-in types through `initialize.capabilities.pluginChats`, open a chat with `pluginChats/open`, and must explicitly subscribe before receiving live `pluginChat/event` notifications. See [RPC](rpc.md) for the protocol. Plugin tabs remain CLI-only unless they opt in.

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
- `reasoning_boundary`
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

These methods are available in all handler types: commands, footers, prompt context renderers, and transcript event observers. `ctx.say` outputs to the active frontend (terminal or RPC) wherever it is called.

The transcript is read-only. Use context methods instead of mutating Kward internals.

## RPC support

Plugins are available in the CLI and RPC backend.

RPC clients can:

- list plugin commands through `commands/list`,
- run plugin commands through `commands/run`,
- run plugin slash commands through `turns/start` input such as `/hello World`.

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
