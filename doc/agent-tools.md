# Agent tools

Agent tools are the model-callable operations Kward uses to inspect projects, change files, run commands, search outside sources, and ask for clarification. Most users do not call these tools directly. You ask for an outcome in natural language, and Kward decides which tools are needed.

Tools are part of Kward's safety and context-management boundary:

- schemas describe what the model is allowed to call,
- Ruby tool objects validate and execute those calls,
- workspace tools stay inside the active workspace by default,
- file-changing tools require the file to be read first,
- large outputs are bounded or compacted before they enter model context,
- full tool outputs are kept in the session record for later inspection.

## Tool categories

| Category | Tools | Guide |
| --- | --- | --- |
| Workspace tools | `list_directory`, `read_file`, `summarize_file_structure`, `write_file`, `edit_file`, `run_shell_command` | [Workspace tools](workspace-tools.md) |
| Web tools | `web_search`, `fetch_content`, `fetch_raw` | [Web search](web-search.md) |
| Code search | `code_search` | [Code search](code-search.md) |
| Context and interaction tools | `read_skill`, `retrieve_tool_output`, `ask_user_question` | [Context tools](context-tools.md) |

## How tools save tokens

Kward tries to keep tool context useful without flooding the model:

- `read_file` reads bounded line ranges and supports continuation with `offset` and `limit`.
- `summarize_file_structure` returns a compact outline for large source files before reading all code.
- Search, fetch, and shell outputs are capped or compacted before model ingestion.
- Repeated identical tool output is replaced with a short reference instead of being sent again.
- Compacted outputs are stored as artifacts that can be reopened with `retrieve_tool_output`.

This lets the assistant reason from focused evidence while preserving access to original outputs when needed.

## How tools are exposed

`Kward::ToolRegistry` builds the available tool objects and the schemas advertised to the model. Some tools are always available in normal CLI/RPC sessions, while others depend on configuration or frontend capability:

- web tools can be hidden with web search configuration,
- `read_skill` is advertised only when skills are available,
- `ask_user_question` is advertised only when the frontend can display structured questions.

Unknown tool calls are recorded as tool results instead of crashing the session, so the model can recover and choose an advertised tool on the next turn.
