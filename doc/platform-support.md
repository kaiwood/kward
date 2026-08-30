# Platform support

Kward is a terminal application built around Ruby, PTYs, filesystem tools, and operating-system command boundaries. The core agent works across Unix-like systems, while a few terminal and sandbox features depend on the host platform.

## Support matrix

| Platform | Support level | Notes |
| --- | --- | --- |
| macOS | Supported | Primary support for the interactive TUI, PTY handoff, editor, shell, Pan, RPC, and Seatbelt command sandboxing. |
| Linux | Supported | Interactive TUI, PTY handoff, editor, shell, Pan, and RPC are supported. Bubblewrap is required for OS-enforced command sandboxing. |
| WSL | Best effort | Core CLI behavior should work under a current WSL environment. Clipboard, browser launch, inline images, PTY controls, and host integration vary by terminal and Windows configuration. |
| Native Windows | Unsupported | Kward currently depends on Unix-style PTY and process behavior. Use WSL rather than a native Windows Ruby installation. |

Kward requires Ruby 3.4 or newer. CI exercises Ruby 3.4 and the current Ruby release on Linux. Releases are developed and used on macOS as well.

## Terminal expectations

Use a modern UTF-8 terminal with ANSI control-sequence support. Basic chat works without optional graphics protocols. Some features depend on terminal capabilities:

- modified keys such as Shift+Return and Ctrl+Tab may be intercepted by the terminal;
- inline images require iTerm2 or a recognized Kitty-compatible terminal;
- full-screen child applications temporarily own the terminal through PTY handoff;
- Nerd Font project-file icons are opt-in because Kward cannot detect the configured font.

See [Interactive composer](composer.md) for keyboard fallbacks and [Embedded shell](shell.md) for PTY behavior.

## Sandboxing

Command sandboxing is opt-in and platform-specific:

- macOS uses Seatbelt profiles;
- Linux uses Bubblewrap and requires a host configuration that permits unprivileged namespaces;
- WSL support depends on the Linux distribution and host namespace policy;
- native Windows has no supported command sandbox backend.

When Kward cannot enforce a requested non-off sandbox mode, it fails closed rather than silently running the model-requested command without that boundary. See [Command sandboxing](sandboxing.md) for setup and exact limits.

## Reporting a platform problem

Run these commands first:

```bash
ruby --version
kward --version
kward doctor
```

When opening a bug report, include the operating system, terminal, Ruby version, Kward version, and the smallest reproduction. Remove credentials, private paths, repository content, and sensitive command output before posting logs.
