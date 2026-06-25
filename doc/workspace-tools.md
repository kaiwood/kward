# Workspace tools

Workspace tools let Kward inspect and change the local project. They are the tools behind prompts such as:

```text
Find where configuration is loaded.
Add a focused test for this behavior.
Run the related test file.
```

Kward normally chooses these tools itself. You do not need to know their exact names to use them, but understanding the boundaries helps explain why Kward sometimes reads before editing or asks before running broad checks.

## Guardrails

Workspace tools use the active workspace as their boundary. File paths are workspace-relative by default, and file tools are guarded so Kward does not edit arbitrary unread files. Guardrails can be disabled with the `tools.workspace_guardrails` setting — see [Configuration](configuration.md#tool-workspace-guardrails). When disabled, file tools can access paths outside the workspace, but shell commands are unaffected since they already run as your OS user.

Important behavior:

- Existing files must be read in the current conversation before `write_file` or `edit_file` can change them.
- Reads are bounded to avoid pulling very large files into context by accident. Files larger than 256 KB cannot be read or edited. Read output is capped at 50 KB or 2,000 lines, whichever comes first.
- Edits use exact text replacement, so accidental partial or fuzzy changes fail instead of guessing.
- Shell commands run as your operating-system user from the workspace. They are powerful and should be treated like commands you run yourself. Command output is capped at 128 KB.

## Reading the workspace

### `list_directory`

Lists entries in a workspace-relative directory. Kward uses it to discover project structure before reading specific files.

Arguments:

- `path`: workspace-relative directory.

### `read_file`

Reads a workspace text file. Output is capped, and Kward can continue with line offsets when it needs more detail. The tool also supports explicit context modes so Kward can start cheap and widen only when needed.

Arguments:

- `path`: workspace-relative file path.
- `offset`: optional 1-indexed start line.
- `limit`: optional maximum number of lines.
- `mode`: optional context mode:
  - `preview`: read a short preview slice, defaulting to 120 lines when `limit` is omitted.
  - `outline`: return only the source declaration outline.
  - `range`: read the requested `offset`/`limit` slice.
  - `full`: read from `offset` until Kward's read caps stop the response.
- `max_bytes`: optional per-call byte budget, capped by Kward's workspace read limit.

A successful read marks the resolved file path as read for the conversation, allowing later edits to that file.

When called without `offset`, `limit`, or `mode` on a file that exceeds 2,000 lines or 50 KB, Kward returns a structure outline (classes, modules, methods) plus the first 120 lines instead of truncating blindly. This helps identify relevant entry points before requesting specific line ranges.

Binary files (detected by null bytes) return an error instead of content.

### `context_budget_stats`

Returns approximate context-budget savings for the current process. The report compares each raw tool result size with the model-facing result after compaction or duplicate replacement, includes per-tool totals, and estimates saved tokens using roughly four bytes per token.

Arguments: none.

These numbers are intentionally approximate and local to the running process. They are useful for seeing whether Kward's budgeting is helping, not for billing.

### `context_for_task`

Builds a compact, task-shaped context bundle from likely workspace files. It ranks files by task terms, includes source outlines, and adds short matching excerpts while respecting an approximate byte budget. This is intentionally lightweight: it does not maintain a persistent index or semantic graph.

Arguments:

- `task`: required task or question to gather context for.
- `paths`: optional files or directories to focus. Defaults to the workspace root.
- `budget`: optional approximate byte budget, default 4,000 and capped at 20,000.

Use this when Kward needs orientation for a bug, review, implementation, or explanation before deciding which exact file ranges to read.

### `summarize_file_structure`

Returns a compact outline of recognizable declarations in a source file, including line ranges and declaration kind where Kward can infer them. Kward uses it when a file may be too large to read fully at first.

Arguments:

- `path`: workspace-relative source file path.

This tool saves tokens by letting Kward identify relevant entry points before requesting exact line ranges with `read_file`. The outline is capped at 80 entries and recognizes common Ruby, JavaScript/TypeScript, Go, Rust, Java, and C#-style declarations with lightweight pattern matching rather than a full parser. Binary files (detected by null bytes) return an error instead of content.

## Changing files

### `write_file`

Writes complete file content. Existing files must be read first. New files can be created when the path is inside the workspace.

Arguments:

- `path`: workspace-relative file path.
- `content`: complete file content.

Use full writes when replacing generated content or creating a new file. For small edits to existing files, Kward should usually prefer `edit_file`.

The result includes a unified diff of the changes, capped at 8 KB with a summary of additions and deletions when truncated.

### `edit_file`

Applies one or more exact replacements to a file that has already been read.

Arguments:

- `path`: workspace-relative file path.
- `edits`: array of replacements:
  - `old_text`: unique exact text to replace.
  - `new_text`: replacement text.

Each `old_text` must match exactly once, and replacements must not overlap. This keeps edits deterministic and avoids broad fuzzy rewriting. Empty `old_text`, multiple matches, and no-op edits (where the result is identical) are all rejected with an error.

The result includes a unified diff of the changes, capped at 8 KB with a summary of additions and deletions when truncated.

## Running commands

### `run_shell_command`

Runs a shell command from the workspace root.

Arguments:

- `command`: command to run.
- `timeout_seconds`: optional timeout, default 30 seconds.

Kward uses shell commands for tests, linters, build checks, and simple repository inspection. Command output is bounded at 128 KB and may be compacted before it is sent back into model context, while the original output remains available in the session record.

The output format is `Exit status: N` followed by `STDOUT:` and `STDERR:` sections. On timeout, Kward sends SIGTERM then SIGKILL after 0.2 seconds and returns a timeout error. Commands support cooperative cancellation when the session is cancelled.

## Token behavior

Workspace tools are intentionally incremental:

1. list directories to find likely files,
2. use `read_file` with `mode: "outline"` or `summarize_file_structure` before reading everything,
3. read focused line ranges with `mode: "range"`, `offset`, `limit`, and optional `max_bytes`,
4. widen to `mode: "full"` only when focused context is insufficient,
5. make exact edits,
6. run focused verification commands.

This keeps the model's context window focused on relevant evidence instead of flooding it with entire repositories or long command output.

For details on how tool outputs are compacted, deduplicated, and retrieved, see [Agent tools](agent-tools.md).
