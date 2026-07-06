# Lifecycle hooks

Lifecycle hooks are deterministic runtime callbacks around Kward's agent workflow. Use them when something must happen because of an event, not because the model remembered an instruction.

Hooks can observe events and return structured decisions to allow, deny, ask for approval, modify supported payloads, warn, retry, or defer. They are currently exposed through trusted Ruby plugins and through command hooks configured in `config.json`.

Hooks run as local code with your user permissions. Do not install hooks you do not trust, and do not put secrets in hook output.

## Hooks versus other extension points

| Need | Use |
| --- | --- |
| Reusable prompt text | Prompt template |
| Model instructions for a task | Skill |
| Repository guidance | `AGENTS.md` |
| New local command/UI behavior | Plugin command |
| Deterministic policy or automation around runtime events | Lifecycle hook |

## Decisions

A hook may return one of these decisions:

| Decision | Meaning |
| --- | --- |
| `allow` | Continue normally. This is also the default for `nil` Ruby hook returns and empty command-hook output. |
| `deny` | Stop the operation and return a declined result. |
| `ask` | Ask the frontend for approval when an approval bridge is available; otherwise Kward treats it as denied for safety. |
| `modify` | Continue with an event-specific payload update. Tool, shell, turn, and model-request hooks currently support useful modifications. |
| `warn` | Continue and record a warning decision. Hook failures are normalized to warnings unless the hook itself returns another decision. |
| `retry` | Reserved for retry-aware lifecycle integrations. |
| `defer` | Reserved for asynchronous follow-up integrations. |

When multiple hooks match one event, they run by ascending `order`. A `deny` stops later hooks. A `modify` updates the payload seen by later hooks.

## Ruby plugin hooks

Register hooks from trusted plugin files in `~/.kward/plugins/*.rb`:

```ruby
Kward.plugin do |plugin|
  plugin.hook "shell_command_before",
    id: "block-release",
    description: "Prevent accidental gem releases",
    order: 10,
    match: { command_regex: "\\bgem push\\b" } do |_event, ctx|
      ctx.deny("Gem releases must use the release checklist.")
    end
end
```

The hook block receives:

- `event`: an immutable `Kward::Hooks::Event`.
- `ctx`: the normal plugin context plus hook decision helpers.

Decision helpers:

```ruby
ctx.allow
ctx.deny("reason")
ctx.ask("confirm this action")
ctx.modify(timeout_seconds: 120)
ctx.warn("continued with warning")
ctx.retry("try again later")
ctx.defer("notify asynchronously")
```

## Command hooks

Command hooks are configured in `~/.kward/config.json` under `hooks`. Kward sends the event as JSON on stdin. The command returns a decision as JSON on stdout.

```json
{
  "hooks": {
    "shell_command_before": [
      {
        "id": "block-release",
        "type": "command",
        "command": "~/.kward/hooks/block-release.rb",
        "timeout_seconds": 5,
        "match": { "command_regex": "\\bgem push\\b" }
      }
    ]
  }
}
```

Example command hook:

```ruby
#!/usr/bin/env ruby
require "json"

event = JSON.parse($stdin.read)
command = event.fetch("payload").fetch("command", "")

if command.match?(/\bgem push\b/)
  puts JSON.dump(decision: "deny", message: "Gem releases must use the release checklist.")
else
  puts JSON.dump(decision: "allow")
end
```

If a command hook prints nothing, Kward treats it as `allow`. If it exits non-zero, times out, or prints invalid JSON, Kward records a warning decision and continues.

## Event shape

Every hook receives this shape:

```json
{
  "id": "hookevt_...",
  "name": "shell_command_before",
  "phase": "before",
  "timestamp": "2026-07-06T12:00:00Z",
  "session": {},
  "turn": {},
  "workspace": { "root": "/path/to/workspace" },
  "frontend": {},
  "agent": { "provider": "codex", "model": "gpt-5.5", "reasoning": "medium" },
  "payload": {}
}
```

Payloads are metadata-oriented by default. Full file contents, secrets, and complete transcripts are not included by default.

## Supported events

### Turn and model events

| Event | Payload highlights | Supported modifications |
| --- | --- | --- |
| `turn_start` | `input`, `display_input` | `input`, `display_input` |
| `turn_context_build_before` | `message_count` | none |
| `turn_context_build_after` | `message_count` | none |
| `model_request_before` | `messages`, `tools`, `provider`, `model`, `reasoning` | request fields |
| `turn_model_request_before` | same as `model_request_before` | none currently consumed |
| `model_response_after_parse` | parsed assistant `message` | none |
| `turn_model_response_complete` | parsed assistant `message` | none |
| `turn_end` | `input`, `answer` | none |

### Tool events

| Event | Payload highlights | Supported modifications |
| --- | --- | --- |
| `tool_call_before` | `tool_name`, `arguments`, `tool_call_id`, `source`, MCP metadata when applicable | `arguments` |
| `tool_call_after` | tool metadata plus `content` | none |
| `tool_call_error` | tool metadata plus `error` | none |
| `tool_result_compacted` | reserved for compaction integrations | none |

### Shell events

| Event | Payload highlights | Supported modifications |
| --- | --- | --- |
| `shell_command_before` | `command`, `timeout_seconds`, `cwd` | `command`, `timeout_seconds` |
| `shell_command_after` | shell metadata plus `content` | none |

### File events

| Event | Payload highlights | Supported modifications |
| --- | --- | --- |
| `file_change_after` | `tool_name`, `operation`, `path`, `files`, `content` | none |

`file_change_after` fires only after successful `write_file` or `edit_file` results.

### MCP events

MCP tools are surfaced through generic tool events with:

- `source: "mcp"`
- `server_name`
- `remote_name`

Use match selectors to target MCP tools:

```json
{
  "match": { "mcp_server": "safari", "mcp_tool": "browser_console_messages" }
}
```

## Match selectors

Hook entries support `match` selectors:

| Selector | Matches |
| --- | --- |
| `event` or `name` | Event name |
| `phase` | `before`, `after`, `during`, or `error` |
| `tool` or `tool_name` | Tool name |
| `mcp_server` or `server` | MCP server name |
| `mcp_tool` or `remote_name` | MCP remote tool name |
| `operation` | File operation such as `write` or `edit` |
| `frontend` | Frontend name when supplied |
| `provider` | Active model provider |
| `model` | Active model |
| `path` or `paths` | File path glob |
| `command_regex` | Ruby regular expression applied to shell command |

Unknown selector keys match same-named payload fields.

## Security notes

- Plugin hooks are trusted Ruby code loaded only from `~/.kward/plugins/*.rb`.
- Command hooks run local commands with your user permissions.
- Workspace hook files are not auto-loaded. This avoids cloned repositories silently executing local code.
- Hook payloads are intentionally bounded and metadata-oriented; avoid logging raw event JSON if your hook receives prompt or command data.
- `ask` decisions fail closed when no approval bridge exists.

## Recipes

### Block dangerous shell commands

```ruby
Kward.plugin do |plugin|
  plugin.hook "shell_command_before", match: { command_regex: "\\brm\\s+-rf\\b" } do |_event, ctx|
    ctx.deny("Refusing recursive forced removal.")
  end
end
```

### Increase timeout for test commands

```ruby
Kward.plugin do |plugin|
  plugin.hook "shell_command_before", match: { command_regex: "\\b(rake|rspec|minitest)\\b" } do |_event, ctx|
    ctx.modify(timeout_seconds: 120)
  end
end
```

### Run a formatter after Ruby edits

```json
{
  "hooks": {
    "file_change_after": [
      {
        "id": "format-ruby",
        "command": "~/.kward/hooks/format-ruby.rb",
        "match": { "paths": ["**/*.rb"] },
        "timeout_seconds": 30
      }
    ]
  }
}
```

The formatter hook can inspect `payload.files` and run the appropriate local command itself.
