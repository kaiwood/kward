# Troubleshooting

This page covers common issues and how to diagnose them. When something is not working, start with `kward doctor` — it checks your config, directories, workspace, model, and auth status in one pass.

## Run `kward doctor` first

`kward doctor` reports the state of your local setup without printing secrets:

```bash
kward doctor
```

It checks that your config file is readable and valid JSON, that the config and session directories are writable, that the workspace exists, which provider and model are active, and which credentials are configured. Use it as the first diagnostic step for any unexpected behavior.

`kward auth status` gives a focused view of credentials only, also without printing secrets:

```bash
kward auth status
```

Kward keeps normal command failures concise. To include a Ruby backtrace while diagnosing an unexpected failure, rerun the command with debug errors enabled:

```bash
KWARD_DEBUG=1 kward "Repeat the failing task"
```

Backtraces can include local paths and implementation details. Review them before sharing them publicly.

## Authentication errors and token expiration

OAuth tokens expire. Kward refreshes access tokens automatically when a refresh token is available, but if the refresh token is missing or expired, requests fail with a provider-specific error:

- OpenAI: `No OpenAI OAuth login found.`
- Anthropic: `No Anthropic OAuth login found.`
- Copilot: `No GitHub Copilot OAuth login found.`
- OpenRouter: `No OpenRouter API key found.`

Re-run login for the affected provider:

```bash
kward login              # OpenAI
kward login anthropic    # Anthropic
kward login openrouter   # OpenRouter
kward login github       # Copilot
```

Or use `/login` inside Kward. See [Authentication](authentication.md) for the full provider flow.

## Provider usage limits and billing errors

Kward detects non-retryable quota and billing errors from providers, including messages such as `quota exceeded`, `insufficient_quota`, `out of credits`, and `monthly usage limit reached`. These are not retried — the request fails immediately.

If you see one of these errors:

- Check your provider dashboard for usage or billing limits.
- For OpenRouter, verify your account balance at [openrouter.ai](https://openrouter.ai).
- For OpenAI, check your organization's usage and billing settings.
- Switch to a different provider or model with `/model` if you have alternative credentials.

## Rate limiting and transient server errors

Kward automatically retries transient failures: HTTP 429 (rate limit) and 5xx server errors. It makes up to 3 attempts total with short backoff delays. Network errors such as timeouts and connection resets are also retried.

If requests fail after retries, you will see a message like `request failed after 3 attempts`. Common causes:

- You are hitting the provider's rate limit. Wait a moment and retry, or reduce request frequency.
- The provider is experiencing an outage. Check the provider's status page.
- Your session context is very large, making each request slower and more likely to time out. Use `/compact` to reduce context.

## Context overflow errors

When a conversation exceeds the model's context window, the provider returns an error such as `prompt is too long` or `exceeds the context window`. Kward detects these and does not retry them.

To resolve context overflow:

- Run `/compact` to summarize and reduce the conversation context.
- Start a new session with `/new` if the current one is no longer needed.
- Enable auto-compaction if it is off — see [Configuration](configuration.md).
- Switch to a model with a larger context window via `/model`.

## `gem install kward` succeeds, but `kward` is not found with rbenv

When using rbenv, RubyGems installs gem executables into the active Ruby version's `bin` directory. rbenv then exposes those executables through shims in `$RBENV_ROOT/shims`.

If `gem install kward` succeeds but `kward` is not available on your `PATH`, first check whether RubyGems installed the executable:

```bash
rbenv which kward
```

If that prints a path such as:

```text
/Users/you/.rbenv/versions/4.0.3/bin/kward
```

then the gem executable exists and the missing command is likely an rbenv shim issue.

Regenerate shims:

```bash
rbenv rehash
```

Then verify the shim exists:

```bash
test -x "$RBENV_ROOT/shims/kward"
```

If `rbenv rehash` fails with an error like:

```text
rbenv: cannot rehash: /Users/you/.rbenv/shims/.rbenv-shim exists
```

remove the stale rbenv prototype shim and rehash again:

```bash
rm -f "$RBENV_ROOT/shims/.rbenv-shim"
rbenv rehash
```

After that, `kward` should be available through the rbenv shim:

```bash
which kward
kward --help
```

This stale `.rbenv-shim` file can be left behind by an interrupted `rbenv rehash` or gem installation. It is local rbenv state, not a Kward packaging issue.

## Still stuck?

If none of the above resolves your issue:

1. Run `kward doctor` and `kward auth status` to gather diagnostics.
2. Check the [Authentication](authentication.md) and [Configuration](configuration.md) docs.
3. Search or report issues at the [Kward issue tracker](https://github.com/kaiwood/kward/issues).
