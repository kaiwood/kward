# OpenRouter-compatible Codex proxy

The example `openrouter_proxy` plugin lets a local application that speaks OpenRouter's Chat Completions API use Kward's signed-in Codex account instead. Kward translates requests to OpenAI's documented ChatGPT-plan Responses API and translates its event stream back to Chat Completions JSON or SSE.

This is a deliberately limited compatibility layer, not a complete OpenRouter replacement.

## Install and configure

Copy the example plugin into Kward's trusted plugin directory:

```bash
mkdir -p ~/.kward/plugins/openrouter_proxy
cp examples/plugins/openrouter_proxy/*.rb ~/.kward/plugins/openrouter_proxy/
```

Log in to Kward with the Codex account you want the proxy to use:

```bash
kward login
```

Configure at least one client-visible model ID to Codex model ID mapping in `~/.kward/config.json`:

```json
{
  "plugins": {
    "com.kward.openrouter-proxy": {
      "port": 4000,
      "model_map": {
        "openai/gpt-5-mini": "gpt-5-mini"
      }
    }
  }
}
```

Set a separate local bearer token in the environment. The plugin reads this secret without displaying it:

```bash
export KWARD_PLUGIN_COM_KWARD_OPENROUTER_PROXY_API_KEY="$(openssl rand -hex 32)"
```

Start the proxy in the foreground:

```bash
kward --openrouter-proxy
```

By default it listens only on `127.0.0.1:4000`. Configure another loopback port with the plugin's `port` setting. The local base URL is `http://127.0.0.1:4000/api/v1`; use the local bearer token as the client's API key.

## Point an application at it

Configure the application's **chat-completions** endpoint/base URL to the local address and its key to the local proxy token. Its model value must match a key in `model_map` exactly. For example, `openai/gpt-5-mini` maps to Codex model `gpt-5-mini`.

For Credence, the reasoning provider currently posts to OpenRouter directly, and the embeddings client separately uses OpenRouter's `/embeddings` endpoint. Pointing only the reasoning call at Kward leaves embeddings on OpenRouter. Keep the real OpenRouter credential for embeddings, and use a separate local proxy credential for chat; if the application shares one API-key setting between these code paths, it needs a small provider-boundary adjustment to separate the chat endpoint/key from the embeddings endpoint/key.

A minimal request looks like:

```bash
curl http://127.0.0.1:4000/api/v1/chat/completions \
  -H "Authorization: Bearer $KWARD_PLUGIN_COM_KWARD_OPENROUTER_PROXY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-5-mini",
    "messages": [
      {"role": "system", "content": "Reply concisely."},
      {"role": "user", "content": "Say hello."}
    ]
  }'
```

Add `"stream": true` to receive Chat Completions SSE chunks. Non-streaming requests are also handled through Kward's upstream Responses stream and returned as one JSON completion.

## Supported API subset

- `POST /api/v1/chat/completions`.
- Streaming and non-streaming text responses.
- `system`, `user`, and `assistant` messages with string content.
- Strict `response_format.type: "json_schema"`.
- `max_tokens`, translated to Responses `max_output_tokens`.
- Explicit model mapping; unconfigured model IDs are rejected.
- OpenAI-compatible JSON errors before streaming starts; error chunks for failures after streaming begins.

Other endpoints and parameters are rejected or unsupported, including embeddings, `GET /models`, image/audio content, model routing, and tool calls. This plugin does not advertise general OpenRouter compatibility. Add an endpoint or parameter only with explicit translation and tests.

## Security and lifecycle

The listener is loopback-only, request sizes and timeouts are bounded, and the local bearer token is distinct from Kward's OAuth credential. The OAuth token is used only by Kward's Codex Responses client; it is not returned to the plugin or forwarded to the local client. Prompts and credentials are not logged. Stop the foreground process to stop the listener; Kward also stops plugin-owned listeners during cleanup.

Kward uses `https://api.openai.com/v1/responses` with `store: false` and `stream: true`, following [OpenAI's documented ChatGPT-plan inference flow](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference) rather than its private ChatGPT backend route. See [plugin documentation](plugins.md) for plugin installation and host APIs, and [OpenRouter's API reference](https://openrouter.ai/docs/api_reference/overview) for the broader API this subset resembles.
