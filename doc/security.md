# Security and trust

Kward can read code, edit files, run commands, call model and search providers, and load local extensions. That makes it useful, but it also means you should treat it like a developer tool running with your account—not like a sandbox.

This guide explains the trust boundaries and gives you a safe way to start work in an unfamiliar repository.

## The short version

- Kward and anything it launches run with your operating-system permissions.
- File tools stay inside the active workspace by default, but shell commands are not sandboxed.
- Existing files must be read before Kward's file tools can edit or overwrite them.
- Plugins, MCP servers, command hooks, and HTTP hooks should be configured only from sources and endpoints you trust.
- Project skills and workspace hooks are disabled until you opt in or trust them.
- Prompts, selected file contents, tool results, and conversation history may be sent to the active model provider as needed to answer a request.
- Web searches, fetched URLs, MCP calls, and HTTP hooks can send additional data to their respective services.

If a task involves secrets, production credentials, customer data, or an untrusted repository, narrow the workspace and tools before asking Kward to act.

## A safe first run in an unfamiliar repository

Start with project-provided extensions disabled, which is the default:

```bash
cd ~/code/unfamiliar-project
kward doctor
kward
```

Then use a read-first workflow:

```text
Inspect the project structure and its AGENTS.md. Do not edit files or run project scripts yet. Tell me what instructions, hooks, skills, plugins, generated files, and risky setup commands I should review first.
```

Before enabling or running anything:

1. Read the workspace `AGENTS.md` and any referenced instructions.
2. Inspect `.kward/hooks.json`, `.kward/skills/`, and `.agents/skills/` yourself.
3. Review setup scripts, package hooks, build files, and shell commands before allowing them to run.
4. Keep project skills disabled unless you trust their instructions.
5. Trust workspace hooks only after reviewing the full file with `kward hooks doctor` and `kward hooks trust`.
6. Do not add repository-provided Ruby files to `~/.kward/plugins` unless you are willing to run them as your user.
7. Ask Kward to explain proposed edits and commands before applying them when the impact is unclear.

For especially sensitive work, use a disposable checkout, container, virtual machine, or restricted operating-system account. Kward's own guardrails do not replace operating-system isolation.

## Workspace access is a guardrail, not a sandbox

Kward's built-in file tools normally resolve paths inside the active workspace. They reject paths outside that boundary, and existing files must be read in the current conversation before `write_file` or `edit_file` can change them.

These protections reduce accidental edits. They do not contain the whole process:

- `run_shell_command`, `!command`, `/shell`, and `/pty` run with your user permissions.
- A shell command can access files, environment variables, processes, and networks available to your account.
- Plugins, command hooks, and MCP servers are local processes with the same general operating-system access.
- Read-before-edit applies to Kward's file tools, not to arbitrary shell commands or extension code.

You can disable the file boundary with `tools.workspace_guardrails: false`, but doing so broadens file-tool access and is rarely needed. See [Workspace tools](workspace-tools.md) for exact limits and [Configuration](configuration.md#Tool_workspace_guardrails) for the setting.

## Tool approvals and policy hooks

The interactive CLI does not ask for blanket approval before every tool call. Built-in guardrails and configured lifecycle hooks still apply, but ordinary file and shell tools can run during a turn.

RPC clients can request per-turn approval with `approvalMode: "ask"`. Kward then emits `tool/approvalRequested` before each tool executes and waits for the client to answer. The default RPC approval mode is `none`.

Lifecycle hooks can add deterministic policy around tools, shell commands, files, Git actions, model requests, and other events. A hook can allow, deny, modify supported data, warn, or ask for approval. An `ask` decision fails closed when the frontend has no approval bridge.

Pan mode does not provide a dedicated hook-approval UI. Use `deny` or `warn` for Pan-facing policies instead of depending on interactive approval.

See [Lifecycle hooks](lifecycle-hooks.md) for policy examples and [RPC protocol](rpc.md#Tool_approval_bridge) for the approval contract.

## Know what you are trusting

### Workspace instructions

A repository-level `AGENTS.md` is guidance for the model, not executable code. Kward tells the model to read it for repository tasks. Instructions can still influence what the model proposes or which tools it calls, so review unfamiliar guidance just as you would review a contributor script.

### Project skills

Project skills under `.kward/skills/` and `.agents/skills/` are skipped by default. Enable them only after reviewing their `SKILL.md` instructions and supporting files:

```text
/settings → Tools & Search → Trust project skills
```

This setting trusts project skills generally; it is not a per-repository digest. A skill's `allowed-tools` metadata does not grant permissions or constrain tools in Kward.

### Workspace hooks

Project hooks in `.kward/hooks.json` run only after `/hooks trust`. Trust is tied to the file digest, so a change invalidates it and requires another review. Command hooks execute local commands; HTTP hooks send event data to their configured endpoint.

### Plugins

Ruby plugins in `~/.kward/plugins/*.rb` run inside the Kward process with your permissions. They can read files and environment variables, write files, run commands, and make network requests. Kward intentionally does not load plugins from a workspace directory.

### MCP servers

Configured MCP servers are local child processes. Their tools can expose application state such as browser pages, console messages, network traffic, or screenshots. Kward currently supports local stdio servers, but local transport does not make an untrusted server safe.

Only add commands you trust to `mcpServers`, and review any environment variables supplied to them. See [MCP servers](mcp.md).

## What leaves your machine

### Model providers

To answer a turn, Kward sends the assembled conversation context to the active model provider. Depending on the task, that context can include:

- your prompts and prior conversation,
- system instructions, personas, skills, memory, and plugin context,
- file content read into the conversation,
- shell and tool results,
- images you attach,
- summaries produced during compaction.

Provider retention and training policies are controlled by the provider and your account or organization. Do not give Kward content you are not permitted to send to that provider.

### Web tools

Search queries go to the selected search provider. `fetch_content` and `fetch_raw` request the URL you provide or the model selects. Disable web tools when external lookup is inappropriate:

```json
{
  "web_search": {
    "enabled": false
  }
}
```

See [Web search](web-search.md#Network_behavior) for provider order and request behavior.

### Hooks and MCP

HTTP hook payloads can include prompts, commands, file paths, tool arguments, and selected event results. Avoid forwarding raw events to third parties. Git and file after-events may include command output or changed content.

MCP tool arguments and results pass between Kward and the configured server. What the MCP server stores or forwards is determined by that server.

## Local data and permissions

Kward keeps user data under `~/.kward` by default, or mostly beside `KWARD_CONFIG_PATH` when that override is set.

| Data | Typical location | Notes |
| --- | --- | --- |
| Main config and OpenRouter key | `~/.kward/config.json` | Do not commit or share it. |
| OAuth credentials | `~/.kward/auth.json`, `anthropic_auth.json`, `github_auth.json` | Written with mode `0600` when possible. |
| Sessions and tool results | `~/.kward/sessions/` | Conversation, file/tool output, and compaction history; files use mode `0600`. |
| Prompt history | `~/.kward/history/` | Workspace-scoped submitted prompts; files use mode `0600`. |
| Memory | `~/.kward/memory/` | Off by default; directory `0700` and files `0600`. |
| Telemetry logs | `~/.kward/logs/` | Off by default; redacted metadata, not intentional prompt or file-content logging. |
| Plugins | `~/.kward/plugins/` | Trusted Ruby code, not private data storage. |
| Hook audit log and trust records | `~/.kward/logs/`, `~/.kward/trusted_workspace_hooks.json` | Audit records use redacted metadata rather than raw event values. |

Private file modes help on normal Unix-like systems but do not protect data from your own account, privileged users, backups, malware, or a compromised machine. Session exports are written to the path you choose and should be protected separately.

Use these commands to inspect or remove stored credentials and context:

```bash
kward auth status
kward auth logout
```

```text
/session
/memory list
/memory forget <id>
```

See [Authentication](authentication.md), [Sessions](session-management.md), [Memory](memory.md), and [Configuration](configuration.md#Logging_and_stats) for retention and management details.

## Practical habits

- Keep secrets out of prompts, screenshots, shell output, plugin context, and hook messages.
- Prefer temporary environment variables to storing short-lived API keys in config.
- Disable web search for private work that should not trigger external requests.
- Keep memory off unless cross-session recall is useful and appropriate.
- Review diffs and `git status` before committing agent changes.
- Treat generated commands as suggestions you are responsible for running.
- Use `kward sysprompt` to inspect instructions assembled for a new conversation.
- Run `kward doctor` and `kward hooks doctor` when configuration or trust behavior is unclear.

Security here is layered: Kward supplies guardrails and explicit trust controls, while real isolation and least privilege come from the environment in which you run it.
