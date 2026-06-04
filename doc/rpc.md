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

- `transcript`: Tauren transcript format support, including normalized messages, image/tool support, and explicit unsupported compaction/reasoning restore flags.
- `sessions`: explicit RPC session mode, JSONL persistence, supported session methods, RPC list support, supported linear-session fork methods, and explicit unsupported compact/import/tree/update features.
- `turns`: async turn mode, per-session concurrency, unsupported busy-input steering, queued follow-up input, best-effort cancellation, and recent in-memory event replay behavior.
- `events`: `turn/event` notification details, assistant/reasoning event names, normalized tool metadata, diff result support, and explicit unsupported shell changed-file detection/session update flags.
- `attachments`: supported input attachment contract for `turns/start`, with accepted base64 image MIME types and a stable max byte value.
- `models`: model/reasoning RPC methods, exposed model fields, and no scoped model support.
- `runtime`: supported state/stats methods with message-count stats; token, cost, and context usage are currently not computed.
- `runtimeSettings`: live `runtime/updateSetting` support for `defaultModel` and `defaultThinkingLevel`, plus `runtime/reload`.
- `auth`: Tauren auth provider format, OpenAI OAuth, OpenRouter API-key login, and provider logout for stored credentials.
- `commands`: supported `commands/list` capability for prompt and skill command sources.
- `startupResources`: supported startup resource listing for context, skills, and prompts.
- `extensionUi`: question bridge support via `ui/question` and `ui/answerQuestion`; other UI primitives are explicitly unsupported.
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

RPC sessions are explicit and have an RPC `id`, a persisted session `path`, and a `workspaceRoot`.

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

Returns recent persisted sessions for that workspace, newest first. Each item includes absolute `path`, `cwd`, `workspaceRoot`, `createdAt`, `modifiedAt`, optional `name`, compact `firstMessage`, and `messageCount` excluding metadata records.

### `sessions/rename`

Params:

- `sessionId`
- `name`

Renames or clears the active persisted session name.

### `sessions/clone`

Params:

- `sessionId`

Creates a new persisted session from the current conversation and returns a new independent RPC session. Future messages in the clone append only to the clone file; the source session remains unchanged.

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

Returns session metadata and full conversation messages.

## Turn methods

Turns are asynchronous. A session queues turns sequentially; only one turn runs per session at a time.

### `turns/start`

Params:

- `sessionId`
- `input`
- `streamingBehavior`: optional; `newTurn` by default, `followUp` queues behind the active turn, and `steer` is currently unsupported.
- `attachments`: optional array of image attachments: `{ "type": "image", "data": "base64", "mimeType": "image/png", "name": "optional.png", "sizeBytes": 12345 }`.

Supported attachment MIME types are `image/png`, `image/jpeg`, `image/gif`, and `image/webp`. Image data must be raw base64 without a `data:` prefix, and the RPC boundary limit is 10MB per image.

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
- `turnStarted`
- `reasoningDelta`
- `assistantDelta`
- `assistantMessage`
- `toolCall`
- `toolResult`
- `answer`
- `turnCancelRequested`
- `error`
- `turnFinished`

Lifecycle payloads include `status` for `turnQueued`, `turnStarted`, and `turnFinished`. Exactly one terminal `turnFinished` is emitted per turn with `status` set to `completed`, `failed`, or `canceled`; failed turns include a sanitized `{ "message": "...", "code": "...", "fatal": false }` error payload.

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

Returns Tauren-compatible runtime state for the session, including session file, persisted session ID/name, current model metadata, current thinking level, streaming/pending-message state, and stable Kward defaults. Unsupported runtime settings are returned as false or omitted.

### `runtime/stats`

Params:

- `sessionId`: active RPC session ID.

Returns session file/id/name plus message-count stats: user messages, assistant messages, tool calls, tool results, and total non-system messages. Token, cost, and context-usage fields are omitted until Kward can compute them.

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

## Model methods

### `models/list`

Returns known model entries from the current client/config backend. This is intentionally simple and may include only defaults/currently configured options. Entries use `{ "provider", "id", "name", "reasoning", "reasoningEffort", "contextWindow", "current" }`; legacy `model` is retained as an alias for older clients.

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

Returns Tauren-compatible slash command metadata for configured prompt templates and skills. Prompt command names omit the leading slash. Skill command names use `skill:<name>`. Builtin terminal-only commands are omitted.

### `resources/startup`

Params:

- `sessionId`: active RPC session ID.

Returns stable startup sections for configured context (`AGENTS.md`), skills, and prompt templates.

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
