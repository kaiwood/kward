# Kward RPC Protocol

<div class="kward-no-toc"></div>

Kward RPC is a JSON-RPC backend protocol for trusted local UI clients. It is versioned as protocol version `1`: new methods and fields may be added in compatible releases, and clients should ignore unknown fields. Removing or changing existing methods or field meanings requires a protocol version bump. Individual capability groups may still report unsupported status in `initialize.capabilities`.

This page is for people building UI clients or integrations. If you use Kward from the terminal, you can skip it.

Prompt history search is a CLI terminal feature only. RPC clients own their composer/input UX and Kward does not currently expose prompt-history read, append, or search methods over RPC.

## Launch

```bash
kward rpc
```

The process uses stdin/stdout exclusively for protocol messages. Diagnostics are written to stderr.

## Framing

Messages are JSON-RPC 2.0 objects framed like LSP messages:

```text
Content-Length: <bytes>\r\n
\r\n
<json body>
```

`Content-Length` is the byte size of the JSON body.

## JSON-RPC

Requests include `jsonrpc: "2.0"`, an `id`, a `method`, and optional `params`. Responses include either `result` or `error`. Notifications omit `id`.

Errors use JSON-RPC codes where possible and include developer diagnostics in `error.data` when available. Tokens, API keys, authorization headers, and similar secret fields are redacted.

## Initialization

### `initialize`

Returns protocol metadata and capabilities.

Result fields:

- `protocolVersion`: currently `1`.
- `serverName`: `"kward"`.
- `experimental`: `false`.
- `capabilities`: includes frontend-neutral capability groups.

Detailed capability fields include:

- `transcript`: Kward transcript format support, including normalized messages, image/tool support, compaction summaries, and restored assistant reasoning as Pi-compatible `thinking` content blocks.
- `sessions`: explicit RPC session mode, JSONL persistence, supported session methods, startup auto-resume capability/default, immediate transcript support for auto-resume, RPC list support, active live-session discovery, supported linear-session fork methods, supported compaction, supported tree navigation with labels and branch summarization, explicit unsupported import support, and unsupported live session updates reported with `notification: "session/updated"`.
- `turns`: async turn mode, per-session concurrency, active/recent turn listing, provider-gated native busy-input steering, queued follow-up input, best-effort cancellation, recent in-memory event replay behavior, per-turn options for model/reasoning/tool scope/tool approval, and structured client context for editor integrations.
- `pluginChats`: optional plugin-owned chats. The capability lists opted-in chat types and methods. Clients must explicitly subscribe before receiving `pluginChat/event` notifications; plugin chats are independent from workspace sessions.
- `events`: `turn/event` notification details, assistant/reasoning event names, normalized tool metadata, tool update/result events, diff result support, configured workspace guardrail status, focused context and context-budget stats tool support, and explicit unsupported shell changed-file detection/session update flags.
- `attachments`: supported input attachment contract for `turns/start`, with accepted base64 image MIME types and a stable max byte value.
- `models`: model/reasoning RPC methods, explicit OpenRouter catalog listing, exposed model fields, and no scoped model support.
- `runtime`: supported state/stats methods with message-count stats and OpenAI/Codex context usage. Cumulative token and cost stats are not computed.
- `lifecycleHooks`: supported lifecycle hook events, decisions, command/plugin/workspace/HTTP/async hook availability, audit log path, hook approval routing through tool approval, and hook notifications (`hook/event`, `hook/message`).
- `runtimeSettings`: live `runtime/updateSetting` support for `defaultModel` and `defaultThinkingLevel`, plus `runtime/reload`.
- `auth`: Kward auth provider format, OpenAI and Anthropic OAuth, OpenRouter API-key login, GitHub/Copilot status reporting, and provider logout for stored credentials. GitHub OAuth login is CLI-only; RPC reports `supported: false` for the GitHub provider with a reason string.
- `memory`: opt-in structured memory support, interactive prompt injection only, JSON/JSONL local storage, and dedicated `memory/*` methods.
- `commands`: supported `commands/list` capability for prompt, skill, and plugin command sources, plus plugin execution through `commands/run` or plugin slash turns.
- `mcp`: local stdio MCP server support through the shared `mcpServers` config. RPC exposes MCP tools to turns and advertises discovery with `methods: ["tools/list", "mcp/status"]`, `toolMetadata: true`, and `serverStatus: true`. MCP resources, prompts, sampling, and Streamable HTTP are explicitly unsupported for now.
- `startupResources`: supported startup resource listing for context, skills, prompts, and plugins.
- `extensionUi`: question bridge support via `ui/question` and `ui/answerQuestion`, plus plugin footer updates via `ui/footer`; other UI primitives are explicitly unsupported.
- `composer`: composer-only UI features. Interactive session diff totals are explicitly unsupported over RPC (`composer.sessionDiff.supported: false`) because RPC clients already receive per-tool diff results and no live composer status payload is exposed. Clipboard copy is also unsupported over RPC (`composer.copy.supported: false`) because UI clients own clipboard access.
- `security`: trusted-local behavior with optional per-turn tool approval. By default there is no workspace mutation guard or tool approval and shell/file mutation can run. File-tool workspace guardrails are reported under `capabilities.events.tools.workspaceGuardrails` and `runtime/state.workspaceGuardrailsEnabled`.
- `export`: supported transcript export formats. Currently `markdown` and `html`; default is `markdown`.
- `starterPack`: explicitly unsupported (`supported: false`, reason `cliOnlyInstallCommand`). Use `kward init` from the shell.
- `shell`: explicitly unsupported (`supported: false`, reason `interactiveTuiOnly`) because `/shell` is the local embedded TUI shell.
- `logging`: local redacted telemetry logging support, the log directory, enabled categories, `methods: ["logging/stats", "logging/tokenCsv"]`, `usageCsv` sub-capability with bucket support, JSONL format, rotation (10 MB, manual retention), config key `logging`, env prefix `KWARD_LOGGING`, and redacted-metadata-only content.

### `shutdown`

Requests process shutdown after the response.

## Workspace methods

### `workspace/validate`

Params:

- `workspaceRoot`: optional path.

Returns the real workspace root. Any existing local directory accessible to the Kward process is allowed.

### `workspace/info`

Returns root, basename, and writability for a workspace.

## Lifecycle hook notifications

RPC clients can subscribe by listening for JSON-RPC notifications:

- `hook/event`: emitted after a lifecycle hook event runs at least one matching handler. The payload includes event identity, phase, timestamp, session/turn/workspace/frontend/agent metadata, sorted `payloadKeys`, and the final decision summary. Raw event payload values are intentionally omitted.
- `hook/message`: emitted when trusted hook/plugin code calls `ctx.say`.

Both notifications are redacted by the same RPC redactor used for other outbound messages.

### `hooks/logs`

Params:

- `limit`: optional positive integer, default `20`, capped at `200`.

Returns `{ path, records }` from the local lifecycle hook audit log. Unreadable JSONL lines are skipped and records are redacted before they are sent over RPC.

## Session methods

RPC sessions are explicit and have an RPC `id`, a persisted session `path`, and a `workspaceRoot`. When a client creates, resumes, clones, or forks into another session, idle empty unnamed sessions are cleaned up automatically.

### `sessions/create`

Params:

- `workspaceRoot`: optional existing directory; defaults to launch cwd.
- `name`: optional session name.
- `resumeLast`: optional boolean. Defaults to the configured `sessions.auto_resume` behavior when omitted by clients that use `sessions/create` for startup. `false` forces a fresh session.

Creates a persisted Kward session and returns session metadata. The response includes `activePersonaLabel` so clients can render the correct avatar immediately. When `resumeLast` is enabled, no `name` is provided, and `sessions.auto_resume` is `true`, Kward resumes the remembered last session for the workspace instead of creating a fresh file; that auto-resume response also includes `resumed: true` and normalized `messages` so clients do not need to briefly render a fresh avatar while fetching transcript state.

### `sessions/resume`

Params:

- `path`: session JSONL path.
- `workspaceRoot`: optional root used to resolve the session path.

Loads a persisted session and returns a new RPC session ID.

### `sessions/list`

Params:

- `workspaceRoot`: optional.
- `limit`: optional; omitted or non-positive values return all sessions.

Returns recent persisted sessions for that workspace in modification-time order. Empty unnamed sessions are deleted during listing. Cloned or forked sessions include parent metadata. Each item includes absolute `path`, `cwd`, `workspaceRoot`, `createdAt`, `modifiedAt`, optional `name`, compact `firstMessage`, `messageCount` excluding metadata records, optional `parentId`/`parentPath`, `depth`, `isLast`, and `ancestorContinues` fields.

### `sessions/rename`

Params:

- `sessionId`
- `name`

Renames or clears the active persisted session name.

### `sessions/clone`

Params:

- `sessionId`

Creates a new persisted session from the current conversation and returns a new independent RPC session with `parentId`/`parentPath` pointing at the source session. Future messages in the clone append only to the clone file; the source session remains unchanged.

### `sessions/compact`

Params:

- `sessionId`
- `customInstructions`: optional additional guidance for the summarizer.

Summarizes older non-system conversation into a structured Ruby-aware checkpoint, keeps recent messages after `firstKeptEntryId` in live context, clears remembered read-file state, and appends a compaction record to the session JSONL. Historical message records remain in the session file for audit/export/navigation.

Returns:

```json
{
  "summary": "Compaction summary",
  "firstKeptEntryId": "message:2",
  "tokensBefore": 1234,
  "details": {
    "read_files": [],
    "modified_files": []
  }
}
```

The server emits `session/event` notifications with `type: "compactionStart"` before summarization and `type: "compactionEnd"` after completion or failure. The end payload includes `{ "result": {}, "aborted": false, "willRetry": false, "errorMessage": null }`; failed compactions set `aborted: true` and return a JSON-RPC error.

### `sessions/forkMessages`

Params:

- `sessionId`

Returns forkable user-message entries for the active session:

```json
{
  "messages": [
    { "entryId": "message:0", "text": "User message text" }
  ]
}
```

`entryId` values are stable message-index IDs within the linear session. `text` is compact display text.

### `sessions/fork`

Params:

- `sessionId`
- `entryId`: an ID returned by `sessions/forkMessages`.

Creates a new independent persisted session from history before the selected user message. The selected user message is excluded from the new session and returned as `text` so clients can place it into the composer for editing/resubmission.

Returns:

```json
{
  "session": {},
  "text": "selected user message text",
  "cancelled": false
}
```

Future messages in the fork append only to the fork file; the source session remains unchanged.

### `sessions/export`

Params:

- `sessionId`
- `path`: optional output path. Explicit paths are resolved relative to the session workspace and must stay inside the workspace or Kward session directory.
- `format`: optional export format, `markdown` or `html`; defaults to `markdown`. `md` is accepted as an alias for `markdown`.

Exports the transcript. Markdown preserves the previous default behavior. HTML is a minimal escaped `<pre>` transcript wrapper.

### `sessions/delete`

Deletes the persisted session file and closes the RPC session.

### `sessions/close`

Closes the RPC session. Empty unnamed session files may be cleaned up.

### `sessions/transcript`

Returns session metadata and full conversation messages. Assistant `reasoning_summary` values and existing `thinking`/`reasoning` content parts are restored as normalized `{ "type": "thinking", "thinking": "..." }` blocks before assistant text; reasoning is not merged into normal text blocks.

### `sessions/active`

Returns currently live RPC sessions in this server process. This is intended for clients reconnecting to an existing local RPC process; it does not list persisted sessions that are not currently open. Use `sessions/list` for persisted session files.

### `sessions/tree`

Params:

- `sessionId`

Returns the full branching session tree as flattened frontend-neutral rows (`kward-tree-items-v1`). Each row includes `entryId`, `parentId`, `role`, `text` (compact display text), `current` (whether it is the active leaf), `depth`, `isLast`, `ancestorContinues`, `activePath`, `selectable`, `label`, `labelTimestamp`, and `prefix` (tree-drawing connector string). User-message entries are selectable; assistant/tool entries are not.

### `sessions/tree/setLabel`

Params:

- `sessionId`
- `entryId`
- `label`: optional display label override for the entry.

Persists a label override for one tree entry and returns `{ "ok": true }`.

### `sessions/tree/navigate`

Params:

- `sessionId`
- `entryId`: a selectable entry ID from `sessions/tree`.
- `summarize`: optional boolean; when true, Kward summarizes the abandoned branch before moving.
- `customInstructions`: optional additional guidance for the summarizer.

Moves the active branch to the selected tree entry. If the entry is a user message, its parent becomes the new active leaf and the user message text is returned as `editorText` so clients can place it into the composer for editing/resubmission. When `summarize` is true, a branch summary is generated and appended to the session before moving.

Returns `{ "session": {}, "editorText": "...", "cancelled": false, "aborted": false }`. Fields with no value are omitted.

## Plugin chat methods

Plugin chats are optional trusted-plugin capabilities, not Kward workspace sessions. When `initialize.capabilities.pluginChats.supported` is true, use `pluginChats/list` to discover available types.

### `pluginChats/open`

Params:

- `typeId`: an opted-in plugin chat type, such as `kward.ensign`.

Opens the plugin-owned chat in this RPC process and returns its metadata plus normalized transcript.

### `pluginChats/transcript`

Params:

- `chatId`;
- `limit`: optional bounded page size for plugin drivers that support transcript paging;
- `before`: optional opaque cursor returned by a preceding page.

Returns chat metadata and its normalized transcript. Paging-capable plugin chats return the newest page first plus `hasMore` and, when more history is available, `nextBefore`. Clients send that cursor as `before` to load the preceding page. Plugins that do not opt in retain the original complete-transcript behavior.

### `pluginChats/subscribe` and `pluginChats/unsubscribe`

Params:

- `chatId`.

Subscriptions are opt-in. `pluginChats/subscribe` enables live `pluginChat/event` notifications for that chat on the current RPC connection. `pluginChats/unsubscribe` disables them without affecting the chat or archive.

### `pluginChats/turns/start`

Params:

- `chatId`;
- `input`;
- `attachments`: optional base64 image attachments using the same MIME and size limits as `turns/start`.

Queues a plugin-chat turn and returns `{ id, chatId, status, ... }`. Plugin chat turns are serialized per chat and do not use workspace sessions, agents, or model overrides.

### `pluginChats/turns/cancel`, `pluginChats/turns/status`, `pluginChats/turns/events`, `pluginChats/turns/list`, `pluginChats/turns/listActive`

These methods mirror the corresponding `turns/*` lifecycle methods, using `chatId` where a list filter is needed. Event replay is bounded in memory and subscriptions are required for live notifications.

## Plugin chat notifications

Subscribed clients receive `pluginChat/event` notifications:

```json
{
  "chatId": "kward.ensign",
  "turnId": "...",
  "sequence": 1,
  "type": "assistantDelta",
  "payload": { "delta": "text" }
}
```

Known event types are `turnQueued`, `turnStarted`, `reasoningDelta`, `reasoningBoundary`, `assistantDelta`, `assistantMessage`, `toolCall`, `toolResult`, `answer`, `turnCancelRequested`, and `turnFinished`.

## Turn methods

Turns are asynchronous. A session queues turns sequentially; only one turn runs per session at a time.

### `turns/start`

Params:

- `sessionId`
- `input`
- `streamingBehavior`: optional; `newTurn` by default when idle. `followUp` queues behind the active turn. `steer` routes input to the active turn only when `initialize.capabilities.turns.busyInput.steer` is `native`; unsupported providers return an invalid params error instead of queueing or approximating steering. When native steering is supported and a turn is already running, omitted `streamingBehavior` defaults to `steer`.
- `attachments`: optional array of image attachments: `{ "type": "image", "data": "base64", "mimeType": "image/png", "name": "optional.png", "sizeBytes": 12345 }`.
- `options`: optional object with per-turn overrides. Supported fields are `provider`, `model`, `reasoningEffort`, `allowedTools`, `disabledTools`, and `approvalMode`. `model` may be a string or an object with `id`/`model`. `allowedTools` and `disabledTools` are arrays of model tool names and are mutually exclusive. `approvalMode` is `none` by default; `ask` emits `tool/approvalRequested` before each tool execution and waits for `tool/answerApproval`. Tool scoping and approval affect only the current turn; they do not change the session or saved config.
- `context`: optional structured client/editor context. Supported fields are `activeFile`, `openFiles`, `selection`, and `diagnostics`. `selection` may include `path`, `startLine`, `endLine`, and `text`; diagnostics may include `path`, `line`, `severity`, and `message`. Kward appends this context to the turn input for model use without persisting it as separate protocol state.

Supported attachment MIME types are `image/png`, `image/jpeg`, `image/gif`, and `image/webp`. Image data must be raw base64 without a `data:` prefix, and the RPC boundary limit is 10MB per image.

If `input` is a configured prompt slash command such as `/plan fix bug`, Kward expands the prompt template server-side before starting the turn. If `input` is a configured plugin slash command such as `/hi_chatgpt`, Kward runs the plugin command and emits its output as turn events without calling the model. Unknown slash commands remain literal input. Clients may still call `prompts/expand` themselves when they need preview/editing before submission.

Returns a turn object with `id`, `sessionId`, `status`, timestamps, and cancellation state. Status starts as `queued` or quickly becomes `running`.

### `turns/cancel`

Params:

- `turnId`

Requests best-effort cancellation. Queued turns can be marked canceled before running. Running turns stop emitting further events when possible, but in-flight model requests or tool side effects may still complete because Ruby/network/tool APIs cannot always be interrupted safely.

### `turns/status`

Returns the current turn object.

### `turns/events`

Params:

- `turnId`
- `afterSequence`: optional sequence number.

Returns recent in-memory events after the requested sequence. Event history is not persisted and is bounded in memory.

### `turns/list`

Params:

- `sessionId`: optional active RPC session ID filter.

Returns recent in-memory turn metadata for this server process. Turn metadata is not persisted across RPC process restarts.

### `turns/listActive`

Params:

- `sessionId`: optional active RPC session ID filter.

Returns queued and running turns for this server process. Use this after reconnecting to rebuild live UI state.

## Turn notifications

The server emits `turn/event` notifications:

```json
{
  "sequence": 1,
  "timestamp": "...",
  "sessionId": "...",
  "turnId": "...",
  "type": "assistantDelta",
  "payload": { "delta": "text" }
}
```

Known event types:

- `turnQueued`
- `turnSteered`
- `steeringApplied`
- `turnStarted`
- `reasoningDelta`
- `reasoningBoundary`
- `assistantDelta`
- `assistantMessage`
- `modelRetry`
- `toolCall`
- `toolUpdate`
- `toolResult`
- `answer`
- `turnCancelRequested`
- `error`
- `turnFinished`

`reasoningBoundary` has an empty payload and marks the end of one reasoning summary message, allowing clients to render the next `reasoningDelta` as a separate block.

Lifecycle payloads include `status` for `turnQueued`, `turnStarted`, and `turnFinished`. Exactly one terminal `turnFinished` is emitted per turn with `status` set to `completed`, `failed`, or `canceled`; failed turns include a sanitized `{ "message": "...", "code": "...", "fatal": false }` error payload.

`modelRetry` is emitted before Kward retries a transient model request failure. Its payload includes `provider`, `model`, `attempt`, `maxAttempts`, `delaySeconds`, and `error`.

`steeringApplied` is emitted after queued steering input has been appended to conversation context. Its payload includes `count`, the number of steering messages applied.

`toolCall`, `toolUpdate`, and `toolResult` payloads include canonical Kward-normalized fields:

- `toolCallId`: tool call ID.
- `toolName`: normalized tool name, such as `read`, `edit`, `write`, or `bash`.
- `args`: normalized arguments. Edit replacements use `oldText`/`newText`; shell timeout is `timeout`.

`toolUpdate` additionally includes `delta.content` and optional `elapsedMs` for clients that want progress/status updates before the final result. Kward currently emits one update after each built-in tool finishes; clients should treat future additional updates as additive.

`toolResult` additionally includes `result` with `content`, `isError`, optional unified `diff`, optional `changedFiles`, and `images`. Failed or declined tools set `isError: true`.

Examples:

- `edit_file`: `toolName: "edit"`, `args: { "path": "...", "edits": [{ "oldText": "...", "newText": "..." }] }`.
- `write_file`: `toolName: "write"`, `args: { "path": "...", "content": "..." }`.
- `run_shell_command`: `toolName: "bash"`, `args: { "command": "...", "timeout": 30 }`.

## Tool approval bridge

When `turns/start` is called with `options.approvalMode: "ask"`, Kward emits `tool/approvalRequested` before executing each tool.

Notification params include:

- `sessionId`
- `approvalRequestId`
- `toolCallId`
- `toolName`
- `args`

Clients answer with `tool/answerApproval`:

Params:

- `sessionId`
- `approvalRequestId`
- `approved`: boolean.

Denied tools are returned to the model as error-like tool results instead of executing the local operation.

## UI question bridge

Kward supports the structured question bridge and plugin footer updates over RPC. The `extensionUi` capability reports `question.supported: true` with `notification: "ui/question"`, `method: "ui/answerQuestion"`, `maxQuestions: 4`, `multiSelect: false`, and `preview: false`. It also reports `footer.supported: true` with `notification: "ui/footer"`. Other Pi-style extension UI primitives (`select`, `confirm`, `input`, `editor`, `widgets`, `custom`, and `terminalInput`) are explicitly reported as unsupported until Kward has a real plugin/extension consumer for them.

Question requests are validated before notification. Kward accepts 1-4 questions, each with 2-4 options, and rejects unsupported `multiSelect` or option `preview` requests.

When the model calls `ask_user_question`, RPC emits a `ui/question` notification:

```json
{
  "sessionId": "...",
  "questionRequestId": "...",
  "questions": []
}
```

When a loaded Kward plugin registers a footer, RPC emits `ui/footer` after session creation/resume/clone and after each completed turn:

```json
{
  "sessionId": "...",
  "text": "custom footer text"
}
```

An empty `text` value clears the client footer.

The UI must respond with `ui/answerQuestion`:

Params:

- `sessionId`
- `questionRequestId`
- `answers`: answer array returned to the tool.

## Runtime methods

### `runtime/state`

Params:

- `sessionId`: active RPC session ID.

Returns frontend-neutral runtime state for the session, including session file, persisted session ID/name, active `rpcSessionId`, `persistentSessionId`, current model metadata, current thinking level, streaming/pending-message state, and stable Kward defaults. Clients must send the active RPC session `id`/`rpcSessionId` in RPC request params. Unsupported runtime settings are returned as false or omitted.

### `runtime/stats`

Params:

- `sessionId`: active RPC session ID.

Returns session file/id/name, active `rpcSessionId`, `persistentSessionId`, message-count stats: user messages, assistant messages, tool calls, tool results, and total non-system messages. Clients must send the active RPC session `id`/`rpcSessionId` in RPC request params. For OpenAI/Codex sessions with a known model context window and text-only non-empty conversation context, also returns `contextUsage` with estimated current next-request context tokens, context window, percent used, and `estimated: true`. Fresh sessions with no non-system content omit `contextUsage` because only static prompt/tool overhead would be measurable. Cumulative token and cost fields are omitted until Kward tracks provider usage responses.

### `runtime/updateSetting`

Params:

- `sessionId`: active RPC session ID.
- `settingId`: currently `defaultModel` or `defaultThinkingLevel`.
- `value`: setting value. `defaultModel` accepts a structured object such as `{ "provider": "OpenRouter", "model": "anthropic/claude-sonnet-4.5" }`. For compatibility, it also accepts `Provider/model-id` strings and preserves slashes after the provider separator.

Applies the setting live by updating config and refreshing client config. Unsupported setting IDs are rejected.

### `runtime/reload`

Params:

- `sessionId`: active RPC session ID.

Refreshes config-backed runtime state and returns `{ "ok": true, "message": "Resources reloaded." }`.

## Logging methods

The `logging` capability reports local redacted telemetry logging support, the log directory, enabled categories, `methods: ["logging/stats", "logging/tokenCsv"]`, `usageCsv` sub-capability with bucket support, JSONL format with 10 MB rotation and manual retention, config key `logging`, env prefix `KWARD_LOGGING`, and redacted-metadata-only content. Logging methods require logging to be enabled by config or environment for at least one category.

### `logging/stats`

Params:

- `range`: optional duration string such as `10 minutes`, `2 days`, or `1 year`; defaults to `1 week`.

Accepted units are minutes, hours, days, weeks, months, and years. Ranges use UTC calendar periods: `1 month` means the current calendar month so far, and `2 months` means the previous month plus the current month so far. Invalid ranges return an invalid-params error with usage text.

Returns structured stats for enabled categories only, including the requested range, log directory, record counts by category/event, `usageStats` token totals, performance duration summaries, tool call summaries, and error counts by event/class/provider/code. Error messages are not included in the stats response.

### `logging/tokenCsv`

Params:

- `range`: optional duration string; defaults to `1 week`.
- `bucket`: optional aggregation bucket: `second`, `minute`, `hour`, `day`, `week`, `month`, or `year`.

Returns `{ "csv": "..." }` with token usage data as CSV. Accepted range units and calendar-period behavior match `logging/stats`. This is the RPC equivalent of `kward stats tokens`.

## Memory methods

Memory is disabled by default. Auto-summary is also disabled by default. RPC memory methods operate on the same local storage as the CLI: `<config-dir>/memory/core.json`, `<config-dir>/memory/soft.jsonl`, and `<config-dir>/memory/events.jsonl`. Retrieved memory is injected only for normal session turns when memory is enabled.

### `memory/status`

Returns `{ "enabled": boolean, "autoSummary": boolean, "paths": { "core", "soft", "events" } }`.

### `memory/enable`

Enables memory in config and creates storage files if needed. Returns `{ "enabled": true }`.

### `memory/disable`

Disables memory prompt injection. Stored memories are left in place. Returns `{ "enabled": false }`.

### `memory/autoSummary/enable`

Enables quiet memory summarization after completed interactive turns. Auto-summary runs only when memory is also enabled. Returns `{ "autoSummary": true }`.

### `memory/autoSummary/disable`

Disables quiet memory summarization after completed interactive turns. Returns `{ "autoSummary": false }`.

### `memory/list`

Params:

- `includeInactive`: optional boolean; includes forgotten soft memories when true.
- `workspaceRoot`: optional workspace root for hierarchy filtering; defaults to the server process workspace.

Returns `{ "global_core": [], "workspace_core": [], "workspace_soft": [] }`.

### `memory/add`

Adds a manual soft memory.

Params:

- `text`: memory text.
- `scope`: optional, defaults to `global`.
- `tags`: optional array.

Returns `{ "memory": {} }`.

### `memory/addCore`

Adds an explicit core memory.

Params:

- `text`: memory text.
- `scope`: optional, defaults to `global`.
- `tags`: optional array.

Returns `{ "memory": {} }`.

### `memory/forget`

Params:

- `id`: memory ID such as `core_001` or `soft_001`.

Returns `{ "forgotten": true }` when a memory was removed or marked forgotten. Core memories are removed. Soft memories are marked inactive and their stored text, tags, confidence, and hit count are redacted.

### `memory/promote`

Promotes an active soft memory to a new workspace core memory and marks the soft memory forgotten, or promotes a workspace core memory to global core.

Params:

- `id`: soft memory ID or workspace core memory ID.

Returns `{ "memory": {} }`.

### `memory/relax`

Downgrades a global core memory to the current workspace hierarchy.

Params:

- `id`: global core memory ID.
- `workspaceRoot`: optional workspace root for the relaxed scope; defaults to the server process workspace.

Returns `{ "memory": {} }`.

### `memory/inspect`

Returns enabled status, storage paths, core memories, and soft memories including inactive records.

### `memory/why`

Params:

- `sessionId`: optional active RPC session ID.

Returns the most recent memory retrieval explanation for the session when provided, otherwise the manager's latest explanation/no-retrieval message.

### `memory/summarize`

Runs conservative heuristic soft-memory inference over the active session and persists any accepted soft memories.

Params:

- `sessionId`: active RPC session ID.

Returns `{ "memories": [] }`.

## Model methods

### `models/list`

Returns known model entries from the current client/config backend. OpenRouter entries come from the local OpenRouter model cache when present; otherwise Kward falls back to defaults/currently configured options. Refresh the cache with the CLI-only `kward openrouter refresh` command. Entries use `{ "provider", "id", "name", "reasoning", "reasoningEffort", "contextWindow", "current" }`.

### `models/current`

Returns the current model entry with `provider`, `id`, `name`, `reasoning`, `reasoningEffort`, `contextWindow`, and `current` where available.

### `models/set`

Params:

- `model`: model ID string.
- `provider`: optional provider hint, currently `Codex` or `OpenRouter`; defaults to the active provider.

Updates the config-backed provider model and returns the current model payload.

### `reasoning/set`

Params:

- `effort`: reasoning effort string.

Updates the config-backed OpenAI/Codex reasoning effort and returns the current model payload.

## Tool and prompt methods

### `tools/list`

Params:

- `sessionId`: optional active RPC session ID. When supplied, returns the exact tool set for that session/workspace. When omitted, returns the default current tool schemas.

Returns current tool schemas. The existing model-facing schema shape is preserved: each entry still has `type: "function"` and `function` with `name`, `description`, and `parameters`. Entries also include additive metadata for UI discovery:

- `metadata.source`: one of practical source labels such as `builtin`, `mcp`, `web`, `skill`, `ui`, or `unknown`.
- `metadata.displayName`: human-readable tool label.
- MCP tools also include `metadata.serverName` and `metadata.remoteName`. The callable name remains sanitized with a double underscore, for example `github__search_issues`, while `displayName` is `github.search_issues`.

Clients that only read `tools[].function` remain compatible.

### `mcp/status`

Returns configured MCP stdio server status without exposing environment values or raw sensitive arguments.

Result shape:

```json
{
  "servers": [
    { "name": "github", "transport": "stdio", "status": "available", "toolCount": 8 },
    { "name": "linear", "transport": "stdio", "status": "unavailable", "toolCount": 0, "error": "Failed to start MCP server linear-mcp: command not found" }
  ]
}
```

Disabled MCP servers are omitted, matching runtime tool exposure. Unsupported MCP capabilities remain unsupported: resources, prompts, sampling, and Streamable HTTP.

### `commands/list`

Params:

- `sessionId`: active RPC session ID.

Returns frontend-neutral slash command metadata for configured prompt templates, skills, and plugins. Prompt command names omit the leading slash. Skill command names use `skill:<name>`. Plugin command names omit the leading slash and include `executable: true`. Builtin terminal-only commands are omitted. Prompt commands can be submitted directly to `turns/start` as slash commands or expanded first with `prompts/expand`; plugin commands can be submitted to `turns/start` or run explicitly with `commands/run`.

### `resources/startup`

Params:

- `sessionId`: active RPC session ID.

Returns stable startup sections for configured context (`PRINCIPLES.md`, or legacy `AGENTS.md`), skills, prompt templates, and plugin slash commands.

### `prompts/list`

Returns configured prompt templates.

### `prompts/expand`

Params:

- `command`: prompt command, with or without leading slash.
- `arguments`: optional string.

Returns expanded prompt text.

## Config and auth methods

### `config/read`

Params:

- `redacted`: optional, defaults to `true`.

Returns the config path and config object. Secret-looking fields are redacted by default.

### `config/update`

Params:

- `values`: object of config keys and values.

Updates config, including secret values, and returns a redacted config object. The stored file contains the supplied values.

### `auth/status`

Returns whether OpenAI OAuth, Anthropic OAuth, OpenAI access token env, and OpenRouter API key env/config are available.

### `auth/providers`

Returns frontend-neutral provider cards for OpenAI OAuth, Anthropic OAuth, OpenRouter API-key auth, and GitHub/Copilot status. Provider cards report whether credentials are configured, whether they came from stored config or environment variables, and whether stored credentials can be removed.

### `auth/loginWithApiKey`

Params:

- `providerId`: currently `openrouter`.
- `apiKey`: API key secret.

Stores the API key with `0600` file permissions, refreshes client config, and returns a redacted message payload. Secret values are not returned.

### `auth/logoutProvider`

Params:

- `providerId`: `openai`, `anthropic`, or `openrouter`.

Removes stored credentials only. Environment variables remain active and are still reported by `auth/providers`.

### `auth/loginWithOAuth`

Params:

- `providerId`: currently `openai` or `anthropic`.
- `timeoutSeconds`: optional callback wait timeout.

Provider-scoped wrapper around the OpenAI or Anthropic OAuth flow. The result includes `providerId`, `loginId`, `authorizationUrl`, `redirectUri`, and `status`.

### `auth/startOpenAILogin`

Starts OAuth without opening a browser. The UI should open `authorizationUrl` and then either let the local callback complete or submit a code/callback URL.

Returns:

- `loginId`
- `authorizationUrl`
- `redirectUri`
- `status`

The server emits `auth/loginFinished` when login completes or fails. The notification includes `providerId`, `loginId`, `status`, `redirectUri`, and optional `message`/`error`.

### `auth/submitOpenAICode`

Params:

- `loginId`
- `code`: authorization code or callback URL.

Completes the login using the submitted code.

### `auth/loginStatus`

Returns login status for a login ID.

## Security and privacy notes

- RPC is intended for a trusted local UI and can read/write files, run shell commands, update secrets, and use OAuth.
- Workspace roots may be any existing local directory accessible to the process.
- Tool execution matches current CLI behavior; mutating tools are not approval-gated by RPC.
- Responses and diagnostics redact secret-looking fields, but clients should still avoid logging full protocol traffic unless necessary.
