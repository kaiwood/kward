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

`writable_roots` lets you grant additional, existing host paths to commands in
`workspace_write` mode—for example, a known local build cache. Configure these
paths only in your user config. Do not add a path merely because a repository
instruction or model response asks for it. `protect_git_metadata` defaults to
`true`; this prevents sandboxed commands from changing `.git`, including
staging and committing changes.

`network` controls child-process network access:

| Value | Child-process network access |
| --- | --- |
| `deny` | Denied by the operating-system backend. This is the default. |
| `allow` | Allowed with the same network reachability as your user account. |

## Interactive controls

Use `/sandbox` in the terminal UI to inspect or update the global policy:

```text
/sandbox status
/sandbox read_only
/sandbox workspace_write
/sandbox off
/sandbox network deny
/sandbox network allow
```

Changes apply to newly created sessions and tabs. Existing turns keep the
workspace and command runner they started with, so start a new session or tab
after changing the mode.

## Worktree tabs

An active worktree-backed tab uses a strict `workspace_write` policy for its
model-requested command workers, regardless of the global `sandbox.mode` or
`tools.workspace_guardrails` settings. The writable root is exactly the linked
worktree and no configured additional writable roots are carried into the tab.
The configured child-network setting is preserved.

If the current platform cannot provide filesystem enforcement, Kward refuses to
activate the worktree instead of falling back to an unrestricted command
worker. The strict agent also disables configured MCP clients and lifecycle
hooks because they run in the Kward host process rather than inside the command
sandbox.

This does not contain the interactive `/shell`, `!command`, or `/pty` features;
those are user-directed host-process operations. Generic model-requested shell
commands still cannot write Git metadata. Active worktree tabs additionally
expose a narrow `git_commit` tool for explicit agent-requested commits; it runs
through the trusted host-side Git workflow rather than widening the shell
sandbox. The interactive `/git` flow remains available for manual review and
commit.

## Platform support

| Platform | Backend | Status |
| --- | --- | --- |
| macOS | Seatbelt through `/usr/bin/sandbox-exec` | Supported for command workers. Kward checks availability at runtime. |
| Linux | Bubblewrap | Supported when `bwrap` can create the required namespaces. |
| Windows | None | Unsupported. A requested non-off policy fails closed. |

On Debian or Ubuntu, install Bubblewrap with `sudo apt install bubblewrap`; on
Fedora, use `sudo dnf install bubblewrap`. A present `bwrap` executable can
still be prevented from creating namespaces by host policy. In that case,
Kward fails the command closed instead of running it unrestricted.

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

Sandboxed command workers receive a minimal environment: Kward preserves only
basic terminal, locale, and path variables, then supplies a private `HOME` and
temporary directory. Credentials and runtime-injection variables are not
inherited. On macOS, Seatbelt also denies reads from common credential locations
under the host home directory, including `.kward`, `.ssh`, `.aws`, `.gnupg`, and
selected cloud/CLI configuration directories.

This is defense in depth, not complete secret-file read isolation: commands
still receive system and development-tool reads needed for normal local work.
On Linux, Bubblewrap provides a read-only view of the host filesystem outside
its explicitly writable paths; it does not hide every file your account can
read. For sensitive repositories, use a disposable checkout, VM, or container
in addition to Kward's command sandbox.

The RPC `initialize.capabilities.security.sandbox` payload reports the active
mode, backend, and whether filesystem and child-network enforcement are active.
It also reports unsupported features, including session pinning and one-time
sandbox elevation; those are not available yet.

## Related guides

- [Security and trust](security.md) explains Kward's broader trust boundaries.
- [Permissions](permissions.md) controls whether Kward starts a model-requested
  tool; it does not constrain a command after it starts.
- [Configuration](configuration.md#Command_sandboxing) covers the full config
  section, while [Workspace tools](workspace-tools.md) explains the separate
  file-tool guardrails.
