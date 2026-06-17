# Memory

Memory lets Kward remember stable preferences and project facts across interactive sessions. It is off by default.

Use memory when you keep telling Kward the same things:

- "This project uses Minitest."
- "Prefer small patches with tests."
- "Do not run destructive database commands."
- "In this workspace, use `bundle exec rake test`."

Leave memory off when every session should start clean.

Memory is not used for one-shot prompts such as `kward "..."`.

## Enable memory

Inside interactive Kward:

```text
/memory enable
```

Disable it again:

```text
/memory disable
```

The setting is stored in `~/.kward/config.json`:

```json
{
  "memory": {
    "enabled": true
  }
}
```

## Add memories yourself

Add a global instruction when it should apply everywhere:

```text
/memory core "Prefer small, focused patches with tests."
```

Add a workspace-specific hint when it only applies to the current project:

```text
/memory add "This workspace uses Minitest."
```

Use global core memory sparingly. It has higher priority than workspace memory.

## Let Kward summarize useful memories

Auto-summary is off by default. Enable it if you want Kward to learn recurring preferences from interactive sessions:

```text
/memory auto-summary enable
```

This only runs when memory is enabled. It does not run for one-shot prompts.

You can also ask Kward to summarize the current session manually:

```text
/memory summarize
```

Kward is conservative about inferred memories and refuses to automatically persist emotional, intimate, romantic, or dependency-forming memories.

## Inspect what Kward remembers

List active memories for the current workspace:

```text
/memory list
```

Show memory files and state:

```text
/memory inspect
```

Explain why memories were used for the most recent turn:

```text
/memory why
```

This is useful when an answer seems influenced by previous context and you want to know why.

## Remove or change memories

Forget a memory:

```text
/memory forget core_001
/memory forget soft_001
```

Promote a workspace hint when it should become a stronger rule:

```text
/memory promote soft_001
```

Relax a global memory back to the current workspace:

```text
/memory relax core_001
```

## How memory is organized

Kward uses three layers:

1. **Global core memories**: explicit user instructions that apply everywhere.
2. **Workspace core memories**: strong instructions for one workspace.
3. **Workspace soft memories**: lower-confidence hints for one workspace.

Core memories override soft memories. Soft memories are treated as hints, not facts.

Kward does not inject every stored memory into every prompt. It retrieves a bounded set that appears relevant to the current turn.

## Where memory is stored

Default files:

```text
~/.kward/memory/core.json
~/.kward/memory/soft.jsonl
~/.kward/memory/events.jsonl
```

`events.jsonl` stores a small audit trail for actions such as enable, add, retrieve, summarize, promote, and forget.

When a soft memory is forgotten, its text is replaced with `[forgotten]` while inactive audit metadata can remain.

If `KWARD_CONFIG_PATH` is set, memory files live beside that config file instead of under `~/.kward`.

## RPC support

The experimental RPC backend exposes memory methods such as `memory/list`, `memory/add`, `memory/forget`, `memory/why`, and `memory/summarize`. See [RPC protocol](rpc.md) if you are building a client.
