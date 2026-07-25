# Local models

Kward can connect to a local model server that provides OpenAI-compatible Chat Completions. This is useful when you want offline development, control over model selection, or a smaller prompt for a local coding model. For comparison with hosted backends, see [Model providers](providers.md#Choosing_between_similar_providers).

Kward connects to an already-running server. It does not install runtimes, download models, choose GPU settings, or load models for you.

## Choose and start a runtime

Use one of these local servers:

| Runtime | Default Kward base URL |
| --- | --- |
| Ollama | `http://127.0.0.1:11434/v1` |
| LM Studio | `http://127.0.0.1:1234/v1` |
| llama.cpp `llama-server` | `http://127.0.0.1:8080/v1` |

Start the server and load a chat model before starting Kward. Then confirm that it reports models:

```bash
curl http://127.0.0.1:11434/v1/models
```

Use the equivalent configured port for LM Studio or llama.cpp.

## Configure Kward

Add a Local provider configuration to `~/.kward/config.json`:

```json
{
  "provider": "local",
  "local_backend": "ollama",
  "local_model": "qwen2.5-coder:7b",
  "local_context_window": 32768
}
```

`local_backend` supplies a default endpoint for `ollama`, `lm_studio`, or `llama_cpp`. Set `local_base_url` when the server uses another host, port, path, Docker address, reverse proxy, or TLS endpoint:

```json
{
  "provider": "local",
  "local_base_url": "http://127.0.0.1:1234/v1",
  "local_model": "loaded-model-id",
  "local_context_window": 32768
}
```

Set `local_context_window` to the context length actually configured for the loaded model. Kward cannot reliably infer it from a local model name. The value lets Kward report meaningful context usage and make safe auto-compaction decisions.

If your local proxy requires a token, set `local_api_key` or `KWARD_LOCAL_API_KEY`. Kward sends it as a bearer token only for Local requests.

You can also choose **Local** from `/settings` → **Model & Reasoning** → **Provider**, then select a model with `/model`.

## Use a minimal replacement prompt

Smaller models often work better with a short, direct prompt. Create a file beside your Kward config, for example `~/.kward/prompts/local-minimal.md`:

```markdown
You are a coding assistant.
Use the provided tools when needed.
Inspect relevant files before changing them.
Make only requested changes and report what changed.
```

Configure it as Kward's replacement system prompt:

```json
{
  "system_prompt": {
    "file": "prompts/local-minimal.md",
    "include_principles": false
  }
}
```

This file is the entire system prompt. Kward does not add its built-in instructions, `PRINCIPLES.md`, memory context, personas, plugin context, skills, or workspace `AGENTS.md` guidance in replacement mode.

If you want Kward's normal prompt but do not want global principles sent on every turn, omit the `file` and disable only principles:

```json
{
  "system_prompt": {
    "include_principles": false
  }
}
```

Check the exact result before relying on it:

```bash
kward sysprompt
kward sysprompt --raw
```

Do not put secrets in a replacement prompt. Its contents are sent to the model and may be stored as a session prompt snapshot.

## Verify tool calling

A coding agent needs more than ordinary chat: the model must request tools with valid arguments and use their results. Start with a safe read-only task:

```text
Read README.md and summarize the project's test command. Do not modify files.
```

Choose a model trained for tool or function calling. If it responds with prose instead of tool calls, use a tool-capable model or make the replacement prompt's tool guidance more explicit.

## Security and limits

The default endpoints use loopback addresses. If you configure another host, Kward can send prompts, workspace-derived content, attachments, and tool results over that connection. Use TLS and authentication for any endpoint outside your machine or trusted private network.

Local model support uses the OpenAI-compatible Chat Completions interface, including streaming text and function/tool calls. Kward does not promise reasoning controls or image support for arbitrary local models.

## Troubleshooting

**No models appear in `/model`**

Confirm the server is running, a model is loaded, and `GET /v1/models` succeeds. You can still set `local_model` manually when discovery is unavailable.

**The model stops early or Kward compacts too soon**

Check `local_context_window`. It must match the server's loaded-model context setting, not just the model's advertised training context.

**Tool calls are malformed or missing**

Use a tool-trained model and a compatible chat template. Test with a read-only task before allowing writes or shell commands.

**The server is slow**

Reduce the model size, reduce context length, verify GPU acceleration in the local runtime, or raise `stream_idle_timeout_seconds` if the server has long silent intervals.
