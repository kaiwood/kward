# Permissions

Kward's permission policy lets you put a human decision between a model-requested tool call and its side effect. It is useful when you want the agent to inspect a project freely, but want to confirm edits, commands, web requests, or MCP calls as they arise.

Permissions are **off by default**. Enabling them does not sandbox Kward or its subprocesses: an allowed shell command still runs with your operating-system user permissions.

## Start with approval mode

Add this to `~/.kward/config.json`, or enable it through your usual configuration workflow:

```json
{
  "permissions": {
    "enabled": true,
    "mode": "ask"
  }
}
```

In `ask` mode, Kward allows ordinary read-only tools and asks before the agent:

- writes or edits a workspace file,
- runs `run_shell_command`,
- searches or fetches content on the web,
- calls an MCP tool.

When approval is required in the interactive CLI, Kward opens a modal overlay. It shows the complete tool arguments, so an approval for `read_skill` includes the requested skill name and relative path, and an approval for a write includes its path and content. Choose **Allow once** to run that one call, **Allow this tool for this session** to allow later calls to the same tool in the current Kward session, or **Deny** to stop it. Pressing `Esc`, cancelling the overlay, or losing the approval bridge denies the call.

### Steer the agent with `Type something`

**Type something** is more than a denial. It stops the requested tool call and sends your text back to the agent as the tool result, so you can redirect its workflow without waiting for it to finish a wrong turn.

For example, the agent may propose this command:

```text
run_shell_command: grep -R "Permission" lib test
```

Choose **Type something** and enter:

```text
Use ack instead of grep; it is installed here and respects our ignore files.
```

Kward does not run `grep`. The agent receives:

```text
Declined: Use ack instead of grep; it is installed here and respects our ignore files.
```

It can then continue by choosing an `ack` command. This is useful for steering details that are difficult to encode in a static rule, such as:

- use the project’s preferred formatter or test runner;
- run a focused test rather than the full suite;
- use a local mirror or a documented API endpoint;
- explain a proposed database command before running it;
- choose an existing project script instead of inventing a new command.

The typed response is part of the conversation, just like a normal follow-up message. It is stored in the session and may be sent to the active model provider. Do not put secrets in it unless that is acceptable for your selected provider and retained session data.

Use this mode first when working in an unfamiliar repository or when you want to review an agent's actions without preventing ordinary exploration.

## Choose a mode

Set `permissions.mode` to one of these values:

| Mode | Good for | Default behavior |
| --- | --- | --- |
| `ask` | Interactive supervised work | Asks before file changes, shell commands, web tools, and MCP tools. |
| `workspace-write` | Routine edits in selected paths | Allows file changes in `write_scopes`; still asks before shell, web, and MCP tools. |
| `read-only` | Code review and investigation | Denies risky tools by default. |
| `deny-by-default` | Automation or tightly controlled runs | Denies risky tools unless an `allow` rule matches. |

All modes leave ordinary read-only Kward tools available. Rules can make a decision more specific; see [Rules and precedence](#Rules_and_precedence).

## Let Kward edit only selected paths

Use `workspace-write` when you want routine changes in known source and test directories without an approval prompt for each edit:

```json
{
  "permissions": {
    "enabled": true,
    "mode": "workspace-write",
    "write_scopes": ["lib/**", "test/**"]
  }
}
```

With this configuration, the agent may edit `lib/` and `test/` without asking. A proposed edit to `README.md` or `config/` is denied by the policy.

`write_scopes` narrows the policy's default workspace-write behavior; it does not broaden Kward's built-in workspace boundary. File tools still stay inside the active workspace by default, and existing files must still be read before Kward can edit them. See [Workspace tools](workspace-tools.md) for those guardrails.

An empty `write_scopes` array permits no default workspace writes. Omit `write_scopes` if you want the `workspace-write` mode to cover the normal workspace file-tool boundary.

## Rules and precedence

Use `allow`, `ask`, and `deny` arrays to describe exceptions. A rule can match these fields:

- `tool` — a model tool name, such as `run_shell_command` or `write_file`;
- `path` — the file-tool path supplied by the model;
- `command` — the requested shell command text;
- `host` — the host in a `fetch_content` or `fetch_raw` URL;
- `source` — currently useful for `mcp` tools.

Patterns support `*` within a path segment and `**` across directories. Rule matching is case-sensitive.

```json
{
  "permissions": {
    "enabled": true,
    "mode": "ask",
    "allow": [
      { "tool": "write_file", "path": "doc/**" },
      { "tool": "fetch_content", "host": "docs.ruby-lang.org" }
    ],
    "ask": [
      { "tool": "run_shell_command", "command": "bundle exec *" }
    ],
    "deny": [
      { "tool": "run_shell_command", "command": "git push*" },
      { "tool": "write_file", "path": "**/.env" }
    ]
  }
}
```

Kward evaluates matching rules in this order:

1. `deny`
2. `ask`
3. `allow`
4. the selected mode's default

A matching deny always wins. An ask rule wins over an allow rule. Keep rules narrow and easy to explain; prefer an exact command or a small path scope over a broad wildcard.

## A practical workflow

For a normal coding task:

1. Enable `ask` mode.
2. Ask Kward to inspect the project and propose a change.
3. Approve the file edit after checking its path and intent.
4. Approve a focused test command, or choose **Type something** to redirect it—for example, “run `bin/test unit` instead of the full suite.”
5. Review the diff and `git status` as usual.

If you repeatedly work in one source tree, move to `workspace-write` with narrow write scopes. Keep shell and network calls in approval mode unless you have a well-understood policy for them.

## RPC and Pan

RPC clients can continue to use the existing per-turn approval bridge:

```json
{
  "approvalMode": "ask"
}
```

That requests an approval notification for every tool call in that turn. The global permission policy is an additional restriction: a deny rule prevents the call even if the RPC client would approve it. If the global policy requires approval, a frontend without an approval bridge fails closed.

Pan currently has no dedicated approval interface. With permissions enabled, a Pan session cannot approve a policy `ask` decision, so Kward denies it. Use `read-only`, explicit allows, or a CLI/RPC frontend when approvals are needed.

## Limits: policy is not a sandbox

The policy runs before Kward dispatches a model-requested tool. It does not constrain what happens after a shell command starts. In particular:

- a permitted shell command can access files, processes, credentials, and network services available to your user account;
- command-text rules are useful review controls, not a reliable way to enforce network destinations or all subprocess behavior;
- direct commands that you type yourself—`!command`, `/shell`, and `/pty`—are treated as your actions and are outside this first policy scope;
- plugins, hooks, and MCP servers are trusted local extensions with their own process access.

For sensitive work, use a restricted operating-system account, container, virtual machine, or disposable checkout. A future OS-enforced sandbox may provide stronger filesystem and network isolation; it is not part of the current permissions feature.

## Related guides

- [Security and trust](security.md): trust boundaries, extensions, and safe work in unfamiliar repositories.
- [Configuration](configuration.md#Permissions): the complete configuration reference.
- [Lifecycle hooks](lifecycle-hooks.md): add trusted local policy or automation around Kward events.
- [RPC protocol](rpc.md#Tool_approval_bridge): implement the approval bridge in an RPC client.
