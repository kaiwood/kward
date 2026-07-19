# Command sandboxing

Kward can optionally apply an operating-system sandbox to model-requested
`run_shell_command` calls. The sandbox is a technical boundary for the command
and every process it starts; it is separate from Kward's [permission
policy](permissions.md), which decides whether Kward should start a tool at all.

Sandboxing is **off by default**. When you request a non-off mode and Kward
cannot enforce it on the current platform, the command is denied rather than
run without the requested boundary.

## Configure a command sandbox

Add a `sandbox` section to your user config, normally `~/.kward/config.json`:

```json
{
  "sandbox": {
    "mode": "workspace_write",
    "network": "deny",
    "writable_roots": [],
    "protect_git_metadata": true
  }
}
```

Available modes are:

| Mode | Command filesystem writes |
| --- | --- |
| `off` | Existing unrestricted command behavior. |
| `read_only` | Workspace writes are denied. Kward gives the command a private temporary directory for command-local scratch files. |
| `workspace_write` | Writes are allowed in the active workspace and the private command temporary directory. |

`writable_roots` is reserved for user-controlled additional writable paths. Do
not add a path merely because a repository instruction or model response asks
for it. `protect_git_metadata` defaults to `true`; this prevents sandboxed
commands from changing `.git`, including staging and committing changes.

## Platform support

| Platform | Backend | Status |
| --- | --- | --- |
| macOS | Seatbelt through `/usr/bin/sandbox-exec` | Supported for command workers. Kward checks availability at runtime. |
| Linux | Bubblewrap | Supported when `bwrap` and the required namespace capabilities are available. |
| Windows | None | Unsupported. A requested non-off policy fails closed. |

The macOS `sandbox-exec` utility is deprecated by Apple. Kward therefore treats
it as a capability-detected backend and verifies enforcement with platform
integration tests. It is not a promise that future macOS releases will retain
this interface.

## Boundaries and limits

The current implementation protects **model-requested command workers only**.
It does not sandbox:

- the Kward Ruby host process;
- model-provider, search-provider, or RPC traffic;
- trusted Ruby plugins;
- MCP servers, lifecycle hooks, `/shell`, `!command`, or `/pty`.

On macOS, the first backend focuses on write and child-network containment. It
allows command reads needed for normal local development, so it is not a secret
file-read isolation boundary. For sensitive repositories, use a disposable
checkout, VM, or container in addition to Kward's command sandbox.

The RPC `initialize.capabilities.security.sandbox` payload reports the active
mode, backend, and whether filesystem and child-network enforcement are active.
It also reports unsupported features, including session pinning and one-time
sandbox elevation; those are not available yet.
