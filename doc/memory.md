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

Use global core memory sparingly. It applies everywhere, so it has a wider blast radius than workspace memory.

## Let Kward summarize useful memories

Auto-summary is off by default. Enable it if you want Kward to learn recurring preferences from interactive sessions:

```text
/memory auto-summary enable
```

Disable it again:

```text
/memory auto-summary disable
```

This only runs when memory is enabled. It does not run for one-shot prompts.

You can also ask Kward to summarize the current session manually:

```text
/memory summarize
```

`/memory learn` is an alias for `/memory summarize`.

Kward is conservative about inferred memories and refuses to automatically persist emotional, intimate, romantic, or dependency-forming memories.

## Inspect what Kward remembers

Running `/memory` with no argument prints a summary of all available subcommands.

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

`/memory promote` also works on workspace core memories, promoting them to global scope so they apply everywhere:

```text
/memory promote core_003
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

Kward does not inject every stored memory into every prompt. It retrieves a bounded set that appears relevant to the current turn: up to 6 core and 6 soft memories. Core memories are included by scope match (global and current workspace). Soft memories are scored by text and tag overlap with the current input, confidence level, and expiry, and only the top-scoring ones are injected.

## Where memory is stored

Default files:

```text
~/.kward/memory/core.json
~/.kward/memory/soft.jsonl
~/.kward/memory/events.jsonl
```

The memory directory is created with mode `0700` and each file with mode `0600`.

`events.jsonl` stores a small audit trail for actions such as enable, add, retrieve, summarize, promote, and forget.

When a soft memory is forgotten, its text is replaced with `[forgotten]` while inactive audit metadata can remain.

Soft memories have a time-to-live of 60 days by default. Each time a soft memory is retrieved, its `last_seen_at` timestamp is updated and its hit count is incremented. If a soft memory is not retrieved within its TTL window, it expires and is no longer injected into prompts. Forgotten and expired memories remain in the file for audit but are not shown in `/memory list`.

If `KWARD_CONFIG_PATH` is set, memory files live beside that config file instead of under `~/.kward`. See [Configuration](configuration.md) for the config-file representation.

## RPC support

The RPC backend exposes memory methods including `memory/status`, `memory/enable`, `memory/disable`, `memory/autoSummary/enable`, `memory/autoSummary/disable`, `memory/list`, `memory/add`, `memory/addCore`, `memory/forget`, `memory/promote`, `memory/relax`, `memory/inspect`, `memory/why`, and `memory/summarize`. See the [RPC documentation](rpc.md) for the full protocol.
