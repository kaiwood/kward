# Context budgeting and token savings

Kward tries to keep the model's context focused. Instead of reading whole files and pasting every byte of command output back into the conversation, it gathers evidence in small steps, compacts noisy output, and keeps the original data available when needed.

This page summarizes the token-saving work in Kward: what existed before, what the newer focused-context tools add, and how those pieces fit together during normal agent work.

## Why this matters

Coding agents spend a lot of tokens just finding the right code. A single broad file read, failed test run, or web fetch can add thousands of tokens to the next model call. That makes sessions slower, more expensive, and more likely to lose the useful details in noise.

Kward's goal is not to build a heavyweight semantic index. It is to stay lightweight and local while giving the agent a disciplined path:

```text
find likely files -> inspect outlines/previews -> read exact ranges -> read full files only when needed
```

## The current workflow

When Kward needs code context, it should usually start with one of these tools:

- `context_for_task` for a compact task-shaped bundle.
- `summarize_file_structure` for a source outline of one file.
- `read_file` with `mode: "outline"` or `mode: "preview"`.

Then it can escalate only as needed:

- `read_file` with `mode: "range"`, `offset`, and `limit` for exact sections.
- `read_file` with `mode: "full"` only when focused context is not enough.

The built-in system prompt tells Kward to follow that escalation path, so these tools are part of normal agent behavior rather than hidden manual features.

## Focused task context

`context_for_task` is the highest-level context-budgeting tool. Give it a task and, optionally, focused paths and a byte budget. It returns a compact text bundle with:

- ranked candidate files (by term-matching score),
- source outlines for each file,
- matching excerpts around task terms (2 lines of context),
- a header with the task, budget, and search terms used.

Tool arguments:

```json
{
  "task": "debug token validation failure",
  "paths": ["lib"],
  "budget": 4000
}
```

- `task` is required.
- `paths` is optional; defaults to the workspace root. Each entry is a file or directory.
- `budget` is optional; defaults to 4,000 bytes, max 20,000.

Limits: at most 8 ranked files are returned, with up to 8 matching excerpts per file. Up to 64 files are scanned. Skipped directories include `.git`, `node_modules`, `vendor`, `tmp`, `log`, `coverage`, `dist`, `build`, `.bundle`, `.yardoc`, and `_yardoc`. Only files with known extensions (`.rb`, `.js`, `.ts`, `.py`, `.go`, `.rs`, `.java`, `.cs`, `.md`, `.yml`, `.json`, etc.) plus `Gemfile` are considered.

This is useful when Kward needs orientation before choosing exact files or line ranges. It is intentionally lightweight: no daemon, no database, no persistent graph, and no semantic/vector index.

## Budgeted file reads

`read_file` supports explicit context modes:

| Mode | Use it when |
| --- | --- |
| `outline` | You need a source declaration outline (classes, modules, methods, functions) with line numbers before reading code. Capped at 80 entries. |
| `preview` | You want a short first look. Defaults to 120 lines when no `limit` is given. Respects `offset` and `limit` if provided. |
| `range` | You know the relevant line range. Uses `offset` and `limit` to read a specific section. |
| `full` | You need the full file content up to Kward's read caps. Functionally identical to `range` but signals full-read intent. |

`range` and `full` behave the same: both read a bounded slice using `offset`, `limit`, and `max_bytes`. The difference is semantic — use `full` when you want everything up to the cap, use `range` when you are targeting a section.

`read_file` also accepts `max_bytes`, which lets Kward request a smaller per-call byte budget. This can only reduce the output below the workspace default (50 KB); it cannot increase it.

Large source files still get special handling when read without a mode: Kward returns an outline plus the first 120 lines instead of blindly flooding context. See [Workspace tools](workspace-tools.md) for the full `read_file` argument reference and read limits.

## Source outlines

`summarize_file_structure` and `read_file` with `mode: "outline"` return compact source outlines. These include recognizable declarations, declaration kind, indentation, and approximate line ranges.

The outline recognizer is deliberately simple. It uses lightweight patterns for common Ruby, JavaScript/TypeScript, Go, Rust, Java, and C#-style declarations. It is not a compiler or LSP replacement, but it is fast and dependency-free. See [Workspace tools](workspace-tools.md) for argument details.

## Output compaction

Kward also saves tokens after tools run.

When a tool output is large enough, Kward compacts it before sending it back into model context. The original output is kept in the session record and can be reopened with `retrieve_tool_output`, including after resuming a saved session that contains the original tool execution record.

The compactor preserves:

- the first 40 lines,
- the last 40 lines,
- error, failure, test, search-result, URL, and heading context,
- separate STDOUT/STDERR sections for shell commands.

This is especially useful for commands like test runs, linters, package installs, and large fetches. The model sees the useful parts first, but the full output is not lost. See [Agent tools](agent-tools.md) for the full compaction strategy and artifact retrieval details.

## Duplicate output reuse

If the same tool output appears again, Kward does not repeat it in model context. Instead, it inserts a short reference to the already-stored artifact.

That helps when commands or searches are retried and return the same large result.

## Session compaction

Kward also supports conversation/session compaction. This is separate from tool-output compaction: instead of trimming one tool result, it summarizes older conversation state so a long session can continue with less context pressure.

Session compaction keeps the working conversation manageable while preserving the session history on disk. Run `/compact` manually, or enable auto-compaction in config — see [Session management](session-management.md) and [Configuration](configuration.md).

## Measuring savings

Use `context_budget_stats` to see approximate savings for the current active conversation since it was opened in this process. These runtime stats are not reconstructed when a saved session is resumed.

It reports:

- tool calls counted,
- original bytes,
- model-facing returned bytes,
- saved bytes,
- estimated tokens saved,
- per-tool breakdown with `calls`, `savedBytes`, `returnedBytes`, and `originalBytes` for each tool.

The token estimate is intentionally rough, using about four bytes per token. It is meant to show whether context budgeting is helping, not to match provider billing exactly. See [Workspace tools](workspace-tools.md) for the tool reference.

## Practical example

A good debugging flow looks like this:

```text
User: Debug why auth token validation fails.
Kward: context_for_task(task: "debug auth token validation", paths: ["lib", "test"], budget: 5000)
Kward: read_file(path: "lib/auth.rb", mode: "range", offset: 40, limit: 80)
Kward: run_shell_command(command: "ruby -Itest test/test_auth.rb")
Kward: retrieve_tool_output(...) only if the compacted test output omitted something important.
```

That gives the model enough evidence to work without reading the whole repository or stuffing every command byte into the next request.
