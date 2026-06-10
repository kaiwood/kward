# Kward RPC Protocol

Kward RPC is an experimental backend protocol for UI clients. It is versioned as protocol version `1`, but method names and payloads may still change while the UI integration is built.

## Launch

```bash
ruby lib/main.rb rpc
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
- `experimental`: `true`.
- `capabilities`: includes detailed Tauren-compatible capability groups. Some legacy simple fields remain for older clients, but `sessions` is now the detailed session capability object.

Detailed capability fields include:

- `transcript`: Tauren transcript format support, including normalized messages, image/tool support, compaction summaries, and restored assistant reasoning as Pi-compatible `thinking` content blocks.
- `sessions`: explicit RPC session mode, JSONL persistence, supported session methods, RPC list support, supported linear-session fork methods, supported compaction, and explicit unsupported import/tree/update features.
- `turns`: async turn mode, per-session concurrency, provider-gated native busy-input steering, queued follow-up input, best-effort cancellation, and recent in-memory event replay behavior.
- `events`: `turn/event` notification details, assistant/reasoning event names, normalized tool metadata, diff result support, and explicit unsupported shell changed-file detection/session update flags.
- `attachments`: supported input attachment contract for `turns/start`, with accepted base64 image MIME types and a stable max byte value.
- `models`: model/reasoning RPC methods, explicit OpenRouter catalog listing, exposed model fields, and no scoped model support.
- `runtime`: supported state/stats methods with message-count stats and OpenAI/Codex context usage. Cumulative token and cost stats are not computed.
- `runtimeSettings`: live `runtime/updateSetting` support for `defaultModel` and `defaultThinkingLevel`, plus `runtime/reload`.
- `auth`: Tauren auth provider format, OpenAI OAuth, OpenRouter API-key login, and provider logout for stored credentials.
- `memory`: opt-in structured memory support, interactive prompt injection only, JSON/JSONL local storage, and dedicated `memory/*` methods.
- `commands`: supported `commands/list` capability for prompt, skill, and plugin command sources, plus plugin execution through `commands/run` or plugin slash turns.
- `startupResources`: supported startup resource listing for context, skills, prompts, and plugins.
- `extensionUi`: question bridge support via `ui/question` and `ui/answerQuestion`; other UI primitives are explicitly unsupported.
- `composer`: composer-only UI features. Interactive session diff totals are explicitly unsupported over RPC (`composer.sessionDiff.supported: false`) because RPC clients already receive per-tool diff results and no live composer status payload is exposed.
- `security`: trusted-local behavior; no workspace mutation guard or tool approval, shell/file mutation can run.
- `export`: supported transcript export formats. Currently `markdown` and `html`; default is `markdown`.

Legacy compatibility fields still present include `asyncTurns`, `turnCancellation`, `turnEventReplay`, `uiQuestions`, `authLogin`, `configUpdate`, `session`, `cancellation`, `eventReplay`, `uiQuestion`, `prompts`, `skills`, `tools`, and `config`.

### `shutdown`

Requests process shutdown after the response.

## Workspace methods

### `workspace/validate`

Params:

- `workspaceRoot`: optional path.

Returns the real workspace root. Any existing local directory accessible to the Kward process is allowed.

### `workspace/info`

Returns root, basename, and writability for a workspace.

## Session methods

RPC sessions are explicit and have an RPC `id`, a persisted session `path`, and a `workspaceRoot`. When a client creates, resumes, clones, or forks into another session, idle empty unnamed sessions are cleaned up automatically.

### `sessions/create`

Params:

- `workspaceRoot`: optional existing directory; defaults to launch cwd.
- `name`: optional session name.

Creates a persisted Kward session and returns session metadata.

### `sessions/resume`

Params:

- `path`: session JSONL path.
- `workspaceRoot`: optional root used to resolve the session path.

Loads a persisted session and returns a new RPC session ID.

### `sessions/list`

Params:

- `workspaceRoot`: optional.
- `limit`: optional, default `20`.

Returns recent persisted sessions for that workspace. Existing sessions without ancestry are roots; cloned or forked sessions include parent metadata and tree display fields. Each item includes absolute `path`, `cwd`, `workspaceRoot`, `createdAt`, `modifiedAt`, optional `name`, compact `firstMessage`, `messageCount` excluding metadata records, optional `parentId`/`parentPath`, `depth`, `isLast`, and `ancestorContinues` for tree rendering.

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
- `path`: optional output path.
- `format`: optional export format, `markdown` or `html`; defaults to `markdown`. `md` is accepted as an alias for `markdown`.

Exports the transcript. Markdown preserves the previous default behavior. HTML is a minimal escaped `<pre>` transcript wrapper.

### `sessions/delete`

Deletes the persisted session file and closes the RPC session.

### `sessions/close`

Closes the RPC session. Empty unnamed session files may be cleaned up.

### `sessions/transcript`

Returns session metadata and full conversation messages. Assistant `reasoning_summary` values and existing `thinking`/`reasoning` content parts are restored as normalized `{ "type": "thinking", "thinking": "..." }` blocks before assistant text; reasoning is not merged into normal text blocks.

## Turn methods

Turns are asynchronous. A session queues turns sequentially; only one turn runs per session at a time.

### `turns/start`

Params:

- `sessionId`
- `input`
- `streamingBehavior`: optional; `newTurn` by default when idle. `followUp` queues behind the active turn. `steer` routes input to the active turn only when `initialize.capabilities.turns.busyInput.steer` is `native`; unsupported providers return an invalid params error instead of queueing or approximating steering. When native steering is supported and a turn is already running, omitted `streamingBehavior` defaults to `steer`.
- `attachments`: optional array of image attachments: `{ "type": "image", "data": "base64", "mimeType": "image/png", "name": "optional.png", "sizeBytes": 12345 }`.

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
- `turnStarted`
- `reasoningDelta`
- `assistantDelta`
- `assistantMessage`
- `modelRetry`
- `toolCall`
- `toolResult`
- `answer`
- `turnCancelRequested`
- `error`
- `turnFinished`

Lifecycle payloads include `status` for `turnQueued`, `turnStarted`, and `turnFinished`. Exactly one terminal `turnFinished` is emitted per turn with `status` set to `completed`, `failed`, or `canceled`; failed turns include a sanitized `{ "message": "...", "code": "...", "fatal": false }` error payload.

`modelRetry` is emitted before Kward retries a transient model request failure. Its payload includes `provider`, `model`, `attempt`, `maxAttempts`, `delaySeconds`, and `error`.

`toolCall` and `toolResult` payloads include canonical Tauren-normalized fields:

- `toolCallId`: tool call ID.
- `toolName`: normalized tool name, such as `read`, `edit`, `write`, or `bash`.
- `args`: normalized arguments. Edit replacements use `oldText`/`newText`; shell timeout is `timeout`.
- `rawToolCall` and `toolCall`: original model tool call for compatibility.
- `tool`: legacy normalized metadata retained for older clients.

`toolResult` additionally includes `result` with `content`, `isError`, optional unified `diff`, optional `changedFiles`, and `images`. Failed or declined tools set `isError: true`.

Examples:

- `edit_file`: `toolName: "edit"`, `args: { "path": "...", "edits": [{ "oldText": "...", "newText": "..." }] }`.
- `write_file`: `toolName: "write"`, `args: { "path": "...", "content": "..." }`.
- `run_shell_command`: `toolName: "bash"`, `args: { "command": "...", "timeout": 30 }`.

## UI question bridge

Kward's only supported extension-style UI surface is the structured question bridge. The `extensionUi` capability reports `question.supported: true` with `notification: "ui/question"`, `method: "ui/answerQuestion"`, `maxQuestions: 4`, `multiSelect: false`, and `preview: false`. Other Pi-style extension UI primitives (`select`, `confirm`, `input`, `editor`, `widgets`, `footer`, `custom`, and `terminalInput`) are explicitly reported as unsupported until Kward has a real plugin/extension consumer for them.

Question requests are validated before notification. Kward accepts 1-4 questions, each with 2-4 options, and rejects unsupported `multiSelect` or option `preview` requests.

When the model calls `ask_user_question`, RPC emits a `ui/question` notification:

```json
{
  "sessionId": "...",
  "questionRequestId": "...",
  "questions": []
}
```

The UI must respond with `ui/answerQuestion`:

Params:

- `sessionId`
- `questionRequestId`
- `answers`: answer array returned to the tool.

## Runtime methods

### `runtime/state`

Params:

- `sessionId`: active RPC session ID.

Returns Tauren-compatible runtime state for the session, including session file, persisted session ID/name, active `rpcSessionId`, `persistentSessionId`, current model metadata, current thinking level, streaming/pending-message state, and stable Kward defaults. The legacy `sessionId` field remains the persisted session ID; clients must send the active RPC session `id`/`rpcSessionId` in RPC request params. Unsupported runtime settings are returned as false or omitted.

### `runtime/stats`

Params:

- `sessionId`: active RPC session ID.

Returns session file/id/name, active `rpcSessionId`, `persistentSessionId`, message-count stats: user messages, assistant messages, tool calls, tool results, and total non-system messages. The legacy `sessionId` field remains the persisted session ID; clients must send the active RPC session `id`/`rpcSessionId` in RPC request params. For OpenAI/Codex sessions with a known model context window and text-only non-empty conversation context, also returns `contextUsage` with estimated current next-request context tokens, context window, percent used, and `estimated: true`. Fresh sessions with no non-system content omit `contextUsage` because only static prompt/tool overhead would be measurable. Cumulative token and cost fields are omitted until Kward tracks provider usage responses.

### `runtime/updateSetting`

Params:

- `sessionId`: active RPC session ID.
- `settingId`: currently `defaultModel` or `defaultThinkingLevel`.
- `value`: setting value. `defaultModel` accepts `Provider/model-id` and preserves slashes after the provider separator.

Applies the setting live by updating config and refreshing client config. Unsupported setting IDs are rejected.

### `runtime/reload`

Params:

- `sessionId`: active RPC session ID.

Refreshes config-backed runtime state and returns `{ "ok": true, "message": "Resources reloaded." }`.

## Logging methods

The `logging` capability reports local redacted telemetry logging support, the log directory, enabled categories, and `methods: ["logging/stats"]`. Logging stats require logging to be enabled by config or environment for at least one category.

### `logging/stats`

Params:

- `range`: optional duration string such as `10 minutes`, `2 days`, or `1 year`; defaults to `1 week`.

Accepted units are minutes, hours, days, weeks, months, and years. Ranges use UTC calendar periods: `1 month` means the current calendar month so far, and `2 months` means the previous month plus the current month so far. Invalid ranges return an invalid-params error with usage text.

Returns structured stats for enabled categories only, including the requested range, log directory, record counts by category/event, `usageStats` token totals, performance duration summaries, tool call summaries, and error counts by event/class/provider/code. Error messages are not included in the stats response.

## Memory methods

Memory is disabled by default. RPC memory methods operate on the same local storage as the CLI: `<config-dir>/memory/core.json`, `<config-dir>/memory/soft.jsonl`, and `<config-dir>/memory/events.jsonl`. Retrieved memory is injected only for normal session turns when memory is enabled.

### `memory/status`

Returns `{ "enabled": boolean, "paths": { "core", "soft", "events" } }`.

### `memory/enable`

Enables memory in config and creates storage files if needed. Returns `{ "enabled": true }`.

### `memory/disable`

Disables memory prompt injection. Stored memories are left in place. Returns `{ "enabled": false }`.

### `memory/list`

Params:

- `includeInactive`: optional boolean; includes forgotten soft memories when true.

Returns `{ "core": [], "soft": [] }`.

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

Returns `{ "forgotten": true }` when a memory was removed or marked forgotten.

### `memory/promote`

Promotes an active soft memory to a new core memory and marks the soft memory forgotten.

Params:

- `id`: soft memory ID.

Returns `{ "memory": {} }` for the new core memory.

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

Returns known model entries from the current client/config backend. OpenRouter entries prefer models available to the configured OpenRouter API key when they can be fetched; otherwise Kward falls back to defaults/currently configured options. Entries use `{ "provider", "id", "name", "reasoning", "reasoningEffort", "contextWindow", "current" }`; legacy `model` is retained as an alias for older clients.

### `openrouter/catalog`

Returns the full OpenRouter model catalog as model entries. This is separate from `models/list`, which prefers models available to the configured API key. Models returned here may still fail at request time if the active OpenRouter key cannot access them.

### `models/current`

Returns the current model entry with `id`, `name`, `reasoning`, `reasoningEffort`, and legacy `model` alias where available.

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

Returns current tool schemas.

### `commands/list`

Params:

- `sessionId`: active RPC session ID.

Returns Tauren-compatible slash command metadata for configured prompt templates, skills, and plugins. Prompt command names omit the leading slash. Skill command names use `skill:<name>`. Plugin command names omit the leading slash and include `executable: true`. Builtin terminal-only commands are omitted. Prompt commands can be submitted directly to `turns/start` as slash commands or expanded first with `prompts/expand`; plugin commands can be submitted to `turns/start` or run explicitly with `commands/run`.

### `resources/startup`

Params:

- `sessionId`: active RPC session ID.

Returns stable startup sections for configured context (`AGENTS.md`), skills, prompt templates, and plugin slash commands.

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

Returns whether OpenAI OAuth, OpenAI access token env, and OpenRouter API key env/config are available.

### `auth/providers`

Returns Tauren-compatible provider cards for OpenAI OAuth and OpenRouter API-key auth. Provider cards report whether credentials are configured, whether they came from stored config or environment variables, and whether stored credentials can be removed.

### `auth/loginWithApiKey`

Params:

- `providerId`: currently `openrouter`.
- `apiKey`: API key secret.

Stores the API key with `0600` file permissions, refreshes client config, and returns a redacted message payload. Secret values are not returned.

### `auth/logoutProvider`

Params:

- `providerId`: `openai` or `openrouter`.

Removes stored credentials only. Environment variables remain active and are still reported by `auth/providers`.

### `auth/loginWithOAuth`

Params:

- `providerId`: currently `openai`.
- `timeoutSeconds`: optional callback wait timeout.

Provider-scoped wrapper around the OpenAI OAuth flow. The result includes `providerId`, `loginId`, `authorizationUrl`, `redirectUri`, and `status`.

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
