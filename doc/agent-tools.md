# Agent tools

Agent tools are the model-callable operations Kward uses to inspect projects, change files, run commands, search outside sources, and ask for clarification. Most users do not call these tools directly. You ask for an outcome in natural language, and Kward decides which tools are needed.

Tools also enforce important boundaries:

- Kward validates every tool call before running it.
- Workspace tools stay inside the active workspace by default (see [Configuration](configuration.md) for the guardrail setting).
- File-changing tools require the file to be read first.
- Large outputs are bounded or compacted before they enter model context.
- Full tool outputs remain available in the session record for later inspection.

## Tool categories

| Category | Tools | Guide |
| --- | --- | --- |
| Workspace tools | `list_directory`, `read_file`, `context_for_task`, `context_budget_stats`, `summarize_file_structure`, `write_file`, `edit_file`, `run_shell_command` | [Workspace tools](workspace-tools.md) |
| Shell prompt tools | `run_shell_command`, `prepare_shell_command` (available only to the transient `?` shell assistant) | [Embedded shell](shell.md) |
| Web tools | `web_search`, `fetch_content`, `fetch_raw` | [Web search](web-search.md) |
| Code search | `code_search` | [Code search](code-search.md) |
| Context and interaction tools | `read_skill`, `retrieve_tool_output`, `ask_user_question` | [Context tools](context-tools.md) |

## How tools save tokens

Kward tries to gather enough evidence without flooding the conversation. It usually starts with focused context tools, then moves from outlines and previews to exact ranges or full files only when needed:

- `read_file` reads bounded line ranges, supports continuation with `offset` and `limit`, and accepts explicit `preview`, `outline`, `range`, and `full` modes with optional per-call byte budgets.
- `context_for_task` builds a task-shaped bundle from ranked files, outlines, and matching excerpts within a caller-supplied byte budget.
- `context_budget_stats` reports approximate active-conversation bytes and estimated tokens saved by compaction and duplicate output replacement.
- `summarize_file_structure` returns a compact outline for large source files before reading all code.
- Search, fetch, and shell outputs are capped or compacted before model ingestion.
- Repeated identical tool output is replaced with a short reference instead of being sent again.
- Compacted outputs are stored as artifacts that can be reopened with `retrieve_tool_output`, including after resuming a saved session that contains the original tool execution record.

When output exceeds 12 KB, Kward keeps the most useful sections in context and stores the original output for later retrieval. The compacted result includes an artifact ID, so Kward can reopen an exact section without repeating the tool call. Error output under 8 KB stays intact so useful failure details are not lost.

See [Context budgeting](context-budgeting.md) for the full compaction strategy, limits, and token-saving workflow.

## How tools are exposed

`Kward::ToolRegistry` builds the available tool objects and the schemas advertised to the model. Kward instructs models to call only tools advertised for the current turn; a restricted RPC turn therefore receives schemas only for its selected set. Some tools are always available in normal CLI/RPC sessions, while others depend on configuration or frontend capability:

- web tools can be hidden with web search configuration,
- `read_skill` is advertised only when skills are available,
- `ask_user_question` is advertised only when the frontend can display structured questions.

When `write_file` or `edit_file` changes an `AGENTS.md` file in the workspace root, Kward automatically rebuilds the system message so the model picks up the new instructions without a restart.

Unknown tool calls are recorded as tool results instead of crashing the session, so the model can recover and choose an advertised tool on the next turn.
