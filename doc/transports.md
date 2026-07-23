# Transports

Transports are trusted local Ruby plugins that connect Kward sessions to an
external messaging or event system. A transport may receive messages from
Telegram, Slack, Discord, email, HTTP, or another service and deliver Kward
responses back through that service.

Transports are adapters. The transport owns the external protocol, identity
mapping, and presentation. Kward owns sessions, agents, tools, persistence,
approvals, and workspace policy.

## Boundary

A transport should use the public transport host API rather than creating an
`Agent`, opening a `SessionStore`, or calling the RPC server directly. This
keeps the same session and tool behavior available to the CLI, RPC clients,
and external transports.

Transport plugins are distinct from plugin-owned tabs:

- A plugin tab owns an independent chat runtime and storage.
- A transport connects an external conversation to a normal Kward session.

Plugins run as trusted local Ruby code. Install only plugins you trust.

## Registration

Transport registration is intentionally separate from transport startup. A
plugin declares a transport and returns an adapter when Kward starts it:

```ruby
Kward.plugin do |plugin|
  plugin.transport(
    "example",
    id: "com.example.transport",
    capabilities: {
      inbound: %i[text],
      outbound: %i[text],
      streaming: :aggregate
    }
  ) do |host, config|
    ExampleTransport.new(host: host, config: config)
  end
end
```

Loading a plugin must not make network connections. Transports are started
explicitly by the transport runtime.

The `id` is a stable identifier used for configuration and persisted transport
state. It must not change after release.

## Message flow

Inbound platform messages are normalized before they reach Kward. A normalized
message contains an external transport ID, conversation ID, actor identity,
message ID, text, attachments, reply context, and an idempotency key.

The transport resolves the external conversation to a Kward session, submits a
turn, and subscribes to normalized turn events. The transport decides whether
to stream, edit, aggregate, or otherwise render those events for its platform.

A delivery failure must not fail the underlying model turn. The transport is
responsible for retrying or reporting delivery failures, while the transcript
and final turn status remain authoritative.

## Interactions

Questions and tool approvals are exposed as transport-neutral interaction
requests. A transport may render them as buttons, forms, replies, or another
platform-specific control. It submits the selected answer through the host
API.

Transports that cannot support interactive approvals must use an explicit
configured fallback policy; they must not leave an agent turn waiting forever.

## Storage and routing

Transport plugins receive namespaced durable storage for state such as:

- external conversation to Kward session bindings,
- polling cursors and webhook update IDs,
- external message IDs used for edits,
- pending interaction mappings, and
- delivery retry state.

Transport storage is separate from Kward session files. External update IDs
should be recorded so duplicate webhook or polling deliveries do not start
duplicate turns.

## Identity and policy

The transport authenticates the external actor, but Kward policy controls what
that actor may do. Policy should constrain allowed actors and conversations,
workspace selection, tools, approvals, concurrency, and quotas.

Untrusted external input must never select an arbitrary local workspace path.
Credentials must not appear in prompts, transcripts, RPC responses, or logs.

## Lifecycle

Transport instances have an explicit lifecycle:

```text
start
stop
health
```

The transport manager owns startup, shutdown, failure isolation, and reload.
A transport should not block the interactive CLI or model-turn workers on a
network operation. A foreground transport runner is the simplest initial
deployment; process supervision and companion processes can be added later.
