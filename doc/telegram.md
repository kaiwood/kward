# Telegram transport

Kward includes a first-party example Telegram transport under
`examples/plugins/`. It uses the Telegram Bot API's long-polling interface and
connects private Telegram chats to normal Kward sessions.

This is trusted local Ruby code. Install it only on a machine where the bot's
workspace and Kward tools may safely run.

## Install the plugin

Copy the packaged plugin into the user plugin directory:

```bash
mkdir -p ~/.kward/plugins
cp -R examples/plugins/telegram ~/.kward/plugins/
```

The package entrypoint is `~/.kward/plugins/telegram/plugin.rb`; its sibling
implementation files are loaded relative to that entrypoint.

The plugin does not connect to Telegram while Kward is loading plugins. It is
started explicitly with `kward transport run com.kward.telegram`.

## Configuration

Configure one fixed workspace and explicit numeric allowlists:

```json
{
  "transports": {
    "com.kward.telegram": {
      "workspace": "/Users/me/src/project",
      "allowed_user_ids": [123456789],
      "allowed_chat_ids": [123456789],
      "poll_timeout_seconds": 25
    }
  }
}
```

Do not put the bot token in the config file. Set it in the environment of the
foreground process instead:

```bash
export TELEGRAM_BOT_TOKEN='replace-with-the-token-from-botfather'
```

The plugin also accepts the transport-specific secret name exposed by the
host, but `TELEGRAM_BOT_TOKEN` is the recommended explicit variable.

## Run it

First check that Kward discovers the plugin:

```bash
kward transport list
```

Then run the personal-assistant transport in the foreground:

```bash
kward transport run com.kward.telegram
```

The plugin also registers `com.kward.telegram.isolated`. It uses the generic
`isolated_chat` execution profile: no tools, no plugin commands, no memory, no
attachments, and no approval interactions. Configure that transport with a
separate empty workspace:

```json
{
  "transports": {
    "com.kward.telegram.isolated": {
      "workspace": "/var/lib/kward-chat/workspace",
      "allowed_user_ids": [123456789],
      "allowed_chat_ids": [123456789],
      "poll_timeout_seconds": 25
    }
  }
}
```

For stronger separation, run it with a dedicated home and config directory
that contain only this plugin:

```bash
HOME=/var/lib/kward-chat \
KWARD_CONFIG_PATH=/var/lib/kward-chat/.kward/config.json \
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
kward transport run com.kward.telegram.isolated
```

The process removes any existing Telegram webhook, validates the bot token,
and begins long polling. Run only one polling process for a bot token; multiple
pollers conflict with each other. Supervise the process externally for
restart-on-failure behavior.

## Current scope

The initial adapter supports:

- private text messages,
- one or more explicitly allowlisted numeric users and chats,
- fixed workspace routing,
- normal Kward session persistence,
- idempotent Telegram update claims,
- final responses split at Telegram's message length limit,
- tool approval buttons and single-question choice buttons for the personal
  transport.

The isolated transport intentionally has no tool or interaction capabilities.

It intentionally does not yet support groups, media uploads, webhooks,
streaming message edits, inline mode, or multiple independent workspace
policies.

The transport allowlist is enforced before external messages reach a Kward
session. Keep the first deployment restricted to one user, one private chat,
one workspace, and conservative tool permissions. Never use incoming Telegram
text to select a workspace or tool scope.

## Account setup boundary

The code is ready for account setup, but no Telegram account, bot token, or
network test is required to run the automated tests. After creating a bot,
set `TELEGRAM_BOT_TOKEN`, replace the placeholder numeric IDs, and test the
foreground process with a private chat first.

See the official [Telegram Bot API](https://core.telegram.org/bots/api) for
BotFather setup, polling behavior, message limits, and callback queries.
