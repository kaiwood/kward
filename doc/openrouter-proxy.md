# OpenRouter-compatible Codex proxy

The optional Kward OpenRouter proxy is a local compatibility endpoint for applications that already speak OpenRouter's OpenAI-compatible chat-completions API. It forwards supported inference requests to the configured Codex account using OpenAI's documented Responses API for ChatGPT-plan access.

## Initial compatibility contract

The first release is deliberately limited to:

- `POST /api/v1/chat/completions`, with both `stream: false` and `stream: true`.
- Text messages using `system`, `user`, and `assistant` roles.
- Strict JSON-schema output requests (`response_format.type: "json_schema"`).
- An explicitly configured mapping from client-visible model IDs to Codex model IDs.
- OpenRouter-style JSON errors before a stream starts and SSE error chunks if an upstream failure occurs after streaming begins.

The proxy does not claim full OpenRouter compatibility. Unsupported request parameters and endpoints must be rejected clearly rather than silently ignored. Embeddings, model discovery, image/audio inputs, routing, and tool calls are outside the initial contract unless implementation work explicitly adds and tests them.

## Streaming contract

Upstream Responses events are translated to OpenAI Chat Completions SSE chunks; upstream event data is never passed through as if it were OpenRouter data. Text deltas become `choices[0].delta.content`; a terminal chunk reports the finish reason and usage when available; the stream ends with `data: [DONE]`. Client disconnects should cancel the upstream request. Non-streaming responses use the same translated event/result model and return one completed Chat Completion JSON object.

## Local security defaults

- Listen on loopback only by default.
- Require a configured local bearer token; never reuse or expose the upstream OAuth token as the local token.
- Bound request size and timeouts, and do not log request bodies, prompts, or credentials.
- Keep model selection within the configured allowlist.

## Credence integration note

Credence uses non-streaming chat completions with strict JSON-schema output. Its embeddings client uses a separate OpenRouter-compatible `/embeddings` endpoint, which this proxy does not implement; embeddings therefore remain on their current provider unless configured separately.
