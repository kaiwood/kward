# Memory

Kward has an opt-in structured memory system for interactive sessions. Memory is designed to be inspectable, explainable, and removable. It is disabled by default.

Memory is not used for one-shot prompts such as `ruby lib/main.rb "..."`.

## Enable or disable memory

In interactive chat:

```text
/memory enable
/memory disable
```

Enabling memory stores this config in `~/.kward/config.json`:

```json
{
  "memory": {
    "enabled": true
  }
}
```

When memory is disabled, Kward does not inject retrieved memories into the prompt.

## Auto-summary

Memory auto-summary is off by default. When both memory and auto-summary are enabled, Kward quietly runs the same learning flow as `/memory summarize` after each completed interactive agent turn, when it is ready for the next user prompt:

```text
/memory auto-summary enable
/memory auto-summary disable
```

The config value is stored as:

```json
{
  "memory": {
    "enabled": true,
    "auto_summary": true
  }
}
```

Auto-summary does not run when memory is disabled and is not used for one-shot prompts.

## Memory layers

### Core memories

Core memories are explicit user instructions. They are high-trust and persistent until removed. Add them only when you intentionally want Kward to remember something:

```text
/memory core "Prefer small, focused patches with tests."
```

Core memories are stored as human-readable JSON in:

```text
~/.kward/memory/core.json
```

### Soft memories

Soft memories are contextual hints, such as workflow preferences or recurring project facts. They are confidence-based and treated as non-authoritative. Add one manually with:

```text
/memory add "This workspace usually uses Minitest."
```

Soft memories are stored as JSON Lines in:

```text
~/.kward/memory/soft.jsonl
```

Kward can also infer soft memories when auto-summary is enabled, or when you explicitly ask it to summarize/learn from the current session:

```text
/memory summarize
```

The v1 inference is conservative and heuristic-based, with optional model-based reformulation when summarization has an available client. Kward refuses to automatically persist inferred emotional, intimate, romantic, or dependency-forming memories.

### Session memories

Session memories are temporary working memory for the current conversation. They are stored with the session JSONL file so resuming a session can restore them, but they are not automatically promoted into core memories.

## Inspect, explain, and remove memory

List memories:

```text
/memory list
```

Inspect memory state and file paths:

```text
/memory inspect
```

Explain why memories were retrieved for the most recent interactive turn:

```text
/memory why
```

Forget a memory:

```text
/memory forget core_001
/memory forget soft_001
```

Promote a soft memory to a core memory:

```text
/memory promote soft_001
```

Promotion creates a new core memory and marks the soft memory forgotten.

## Retrieval behavior

For each interactive turn, Kward selectively retrieves memories using:

- scope: `global` and `workspace:<canonical path>`
- core memories first
- soft-memory text and tag overlap with the current input
- soft-memory confidence
- soft-memory recency/TTL
- hard limits on injected memory count

Retrieved memories are injected into the system prompt as a bounded block similar to:

```text
<kward_memory>
Core Memories:
- [core_001] ...

Relevant Soft Memories:
- [soft_001] ...

Rules:
- Core memories override soft memories.
- Soft memories are contextual hints, not guaranteed facts.
</kward_memory>
```

Kward never injects every stored memory.

## Storage and audit trail

Default files:

```text
~/.kward/memory/core.json
~/.kward/memory/soft.jsonl
~/.kward/memory/events.jsonl
```

`events.jsonl` records minimal audit events such as enable, disable, add, forget, promote, retrieve, and summarize. Audit events use IDs, scopes, tags, and timestamps rather than full memory text where practical.

If `KWARD_CONFIG_PATH` is set, memory files live beside that config file instead of under `~/.kward`.

## RPC methods

The experimental RPC backend exposes dedicated memory methods:

- `memory/status`
- `memory/enable`
- `memory/disable`
- `memory/autoSummary/enable`
- `memory/autoSummary/disable`
- `memory/list`
- `memory/add`
- `memory/addCore`
- `memory/forget`
- `memory/promote`
- `memory/inspect`
- `memory/why`
- `memory/summarize`

See [RPC protocol](rpc.md) for method details.
