# Pan mode

Pan mode is Kward's browser interface for a workspace. It gives you a mobile-friendly transcript, prompt composer, live tool activity, and access to recent sessions while Kward continues running on your development machine.

Use it when you want to work from another browser or device on a trusted network without running the full terminal UI there.

## Before you start

Pan is a small local HTTP server, not a hosted service. The machine running Kward performs model requests, reads and edits workspace files, runs tools, and stores sessions.

Pan requires HTTP Basic Auth. Add credentials to `~/.kward/config.json`:

```json
{
  "pan_mode": {
    "host": "0.0.0.0",
    "port": 8765,
    "username": "kward",
    "password": "choose-a-long-private-password"
  }
}
```

The defaults are:

- `host`: `0.0.0.0`, which listens on all network interfaces.
- `port`: `8765`.

Kward refuses to start Pan unless both `username` and `password` are configured. The password is stored as plaintext in your config file, so do not reuse an important password or share the file.

For access from the same machine only, bind to loopback instead:

```json
{
  "pan_mode": {
    "host": "127.0.0.1",
    "port": 8765,
    "username": "kward",
    "password": "choose-a-long-private-password"
  }
}
```

## Start Pan

Run Pan from the project it should control:

```bash
cd ~/code/my-project
kward pan
```

Or select the workspace explicitly:

```bash
kward --working-directory ~/code/my-project pan
```

Kward prints the listening address, workspace, and initial session path. With the default LAN binding, open port `8765` through the machine's LAN address, for example:

```text
http://192.168.1.25:8765/
```

Your browser asks for the configured Basic Auth username and password.

Press `Ctrl+C` in the server terminal to stop Pan. Closing a browser tab does not stop the server or an active turn.

## A normal workflow

1. Start Pan in the workspace you want to use.
2. Open the printed address in a browser and sign in.
3. Enter a concrete request in the composer:

   ```text
   Review the current changes, inspect the affected files, and run the focused tests.
   ```

4. Watch reasoning, tool calls, tool output, retries, and the answer stream into the transcript.
5. Continue in the same session, or use the session sidebar to switch work.

Press Return to send. Use Shift+Return for a new line. The composer grows with multiline input up to its display limit.

Prompts are accepted while another turn is running. Pan puts them into a single queue and executes them sequentially. The status below the composer shows whether Kward is working and how many prompts remain queued.

## Work with sessions

Pan saves conversations through the same workspace-scoped session store as the interactive CLI. The session sidebar shows up to 50 recent sessions with their title, modified time, and message count.

From the sidebar you can:

- select a session to resume it,
- create a new session,
- rename the active session,
- delete the active session.

On smaller screens, use the menu button to open the session drawer. Selecting a session closes the drawer and loads its transcript.

A few details matter:

- Pan starts with a new session when the server launches.
- Creating or resuming a session rebuilds the active conversation and agent around it.
- You cannot create, resume, rename, or delete sessions while a turn is active or prompts are queued. Wait for the queue to finish.
- Deleting the active session creates and activates a replacement session first.
- Pan asks for confirmation before deletion. The interface does not provide an undo action.
- Sessions remain available to the terminal CLI through `/session` because both frontends use the same session files.

See [Sessions](session-management.md) for storage, exports, forks, compaction, and other session operations that remain CLI-oriented.

## Tools and live output

Pan creates the normal Kward agent tool registry for the selected workspace. Depending on configuration, the model can use file, shell, web, code-search, skill, and MCP tools just as it can in a normal agent turn.

The transcript displays:

- user prompts,
- streamed reasoning and assistant text,
- tool names and arguments,
- tool results,
- retries and errors,
- restored compaction summaries and prior session content.

Structured clarification questions are disabled in Pan because it does not have the interactive question picker. Ask the model to state uncertainties in the transcript when a task needs your decision.

Pan does not reproduce terminal-only interfaces such as `/git`, `/files`, `/shell`, the integrated editor, settings pickers, tabs, or clipboard commands. Use natural-language requests for agent work and return to the CLI for those local UI workflows.

## Hooks and plugins

Pan runs configured command hooks and trusted plugin lifecycle hooks. Hook events and messages can appear in the browser's live event stream.

Pan does not provide a dedicated approval interface for hook `ask` decisions. An approval request without a bridge fails closed, so use deterministic `deny` or non-blocking `warn` policies for Pan-facing hooks.

Other plugin UI features, such as custom terminal commands, footers, or interactive canvas commands, are designed for the CLI or RPC clients and do not become controls in the Pan page.

See [Lifecycle hooks](lifecycle-hooks.md#Frontend_support) and [Plugins](plugins.md) for the supported extension surfaces.

## Network and security

Pan exposes powerful agent tools through ordinary HTTP. Basic Auth protects every page and endpoint, but Pan does not provide TLS.

Use these precautions:

- Run it only on a network and machine you trust.
- Prefer `127.0.0.1` when remote access is unnecessary.
- Do not expose the port directly to the public internet.
- Do not put Pan behind a public tunnel unless you provide a properly secured TLS/authentication boundary and understand the risk.
- Use a unique password and protect `config.json`.
- Remember that anyone with the credentials can submit prompts that cause file reads, edits, shell commands, web requests, or MCP calls with your account's permissions.
- Stop the server when you are finished.

Multiple authenticated browser tabs connect to the same Pan process, active session, prompt queue, and workspace. They are not isolated users. A session change or prompt submitted in one connected browser is visible to the others.

Read [Security and trust](security.md) before using Pan with sensitive data or an unfamiliar repository.

## Notes and limitations

- Pan serves one configured workspace per process.
- Turns run one at a time; queued prompts cannot be reordered or cancelled from the page.
- Session changes are blocked until all active and queued work finishes.
- There is no model or reasoning picker in the page; Pan uses the configured client defaults when it creates a conversation.
- There is no dedicated tool-approval UI or structured-question UI.
- The browser reconnects its event stream after a connection interruption, but events emitted while disconnected are not replayed through that stream. Reloading restores the persisted transcript.
- Request bodies are limited to 64 KB.
- Pan displays image entries from restored transcripts as text placeholders rather than rendering attached image data.
- The server is intentionally small and does not replace the richer CLI or the integration-oriented [RPC protocol](rpc.md).
