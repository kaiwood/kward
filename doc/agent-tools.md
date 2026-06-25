# Agent tools

Agent tools are the model-callable operations Kward uses to inspect projects, change files, run commands, search outside sources, and ask for clarification. Most users do not call these tools directly. You ask for an outcome in natural language, and Kward decides which tools are needed.

Tools are part of Kward's safety and context-management boundary:

- schemas describe what the model is allowed to call,
- Ruby tool objects validate and execute those calls,
- workspace tools stay inside the active workspace by default (see [Configuration](configuration.md#tool-workspace-guardrails) for the guardrail setting),
- file-changing tools require the file to be read first,
- mutation tools (`edit_file`, `write_file`, `run_shell_command`) are gated by a write lock when agent workers are active, so only one worker can change the workspace at a time,
- large outputs are bounded or compacted before they enter model context,
- full tool outputs are kept in the session record for later inspection.

## Tool categories

| Category | Tools | Guide |
| --- | --- | --- |
| Workspace tools | `list_directory`, `read_file`, `context_for_task`, `context_budget_stats`, `summarize_file_structure`, `write_file`, `edit_file`, `run_shell_command` | [Workspace tools](workspace-tools.md) |
| Web tools | `web_search`, `fetch_content`, `fetch_raw` | [Web search](web-search.md) |
| Code search | `code_search` | [Code search](code-search.md) |
| Context and interaction tools | `read_skill`, `retrieve_tool_output`, `ask_user_question` | [Context tools](context-tools.md) |

## How tools save tokens

Kward tries to keep tool context useful without flooding the model. The built-in prompt tells Kward to start with focused context tools and escalate from outlines/previews to exact ranges before full-file reads:

- `read_file` reads bounded line ranges, supports continuation with `offset` and `limit`, and accepts explicit `preview`, `outline`, `range`, and `full` modes with optional per-call byte budgets.
- `context_for_task` builds a task-shaped bundle from ranked files, outlines, and matching excerpts within a caller-supplied byte budget.
- `context_budget_stats` reports approximate per-process bytes and estimated tokens saved by compaction and duplicate output replacement.
- `summarize_file_structure` returns a compact outline for large source files before reading all code.
- Search, fetch, and shell outputs are capped or compacted before model ingestion.
- Repeated identical tool output is replaced with a short reference instead of being sent again.
- Compacted outputs are stored as artifacts that can be reopened with `retrieve_tool_output`.

When a tool output exceeds 12 KB, Kward compacts it before sending it to the model. The compactor preserves the first 40 and last 40 lines, keeps lines matching error, test, or search-result patterns with 2 lines of surrounding context, and replaces omitted sections with `[... omitted lines ...]` markers. Shell command output is section-aware: STDOUT and STDERR sections are compacted separately. Compacted outputs include a header with the original and compacted byte counts and the artifact ID for retrieval. Error outputs under 8 KB are left intact so failure details stay visible.

This lets the assistant reason from focused evidence while preserving access to original outputs when needed. For a fuller overview of Kward's context budgeting and token-saving work, see [Context budgeting](context-budgeting.md).

## How tools are exposed

`Kward::ToolRegistry` builds the available tool objects and the schemas advertised to the model. Some tools are always available in normal CLI/RPC sessions, while others depend on configuration or frontend capability:

- web tools can be hidden with web search configuration,
- `read_skill` is advertised only when skills are available,
- `ask_user_question` is advertised only when the frontend can display structured questions.

When agent workers are active, the registry can scope each worker to a subset of tools via an allowed-tool-names filter, so workers only see the tools they need.

When `write_file` or `edit_file` changes an `AGENTS.md` file in the workspace root, Kward automatically rebuilds the system message so the model picks up the new instructions without a restart.

Unknown tool calls are recorded as tool results instead of crashing the session, so the model can recover and choose an advertised tool on the next turn.
