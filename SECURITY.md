# Security policy

Kward can read files, edit workspaces, run commands, call external providers, and load trusted local extensions. Security reports are taken seriously, especially when they involve credential exposure, workspace-boundary bypasses, command execution, authentication, or remote access.

## Supported versions

Security fixes are made against the latest released version and the `main` branch. Upgrade to the newest Kward release before reporting behavior that may already have been fixed.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting form:

<https://github.com/kaiwood/kward/security/advisories/new>

Include, when available:

- the affected Kward version and platform;
- a concise description of the impact;
- reproducible steps or a minimal proof of concept;
- the expected security boundary;
- any suggested mitigation.

Do not include real API keys, OAuth tokens, customer data, private repository content, or other secrets. Use clearly fake fixtures and redact local paths when they are not relevant.

The maintainer will aim to acknowledge a complete report within seven days, validate its impact, coordinate a fix, and agree on disclosure timing. Complex reports may take longer to investigate.

## Security model

Before reporting expected behavior as a vulnerability, review [Security and trust](doc/security.md), [Permissions](doc/permissions.md), and [Command sandboxing](doc/sandboxing.md). Kward's host process, user-directed shell features, and trusted extensions normally run with the current user's permissions; workspace guardrails and command-worker sandboxing have narrower documented boundaries.
