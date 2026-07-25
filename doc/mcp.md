# MCP servers

Kward can connect to local [Model Context Protocol](https://modelcontextprotocol.io/) servers and expose their tools to the model alongside Kward's built-in workspace tools.

This is useful when another app ships an MCP server for something Kward should be able to inspect or control. For example, Safari Technology Preview includes a Safari MCP server that lets agents inspect pages, console output, network activity, screenshots, and other browser state.

## Configure a local MCP server

Add an `mcpServers` object to your Kward config file:

```json
{
  "mcpServers": {
    "safari": {
      "command": "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver",
      "args": ["--mcp"],
      "enabled": true
    }
  }
}
```

Kward starts enabled MCP servers with stdio transport, discovers their tools, and advertises those tools to the model. Tool names are prefixed with the server name so they do not collide with built-in tools or tools from another MCP server.

For the Safari MCP server, install Safari Technology Preview and enable:

1. Safari Settings > Advanced > Show features for web developers
2. Safari Settings > Developer > Enable remote automation and external agents

Then ask Kward something like:

```text
Open http://localhost:3000 in Safari and check the console for errors.
```

or:

```text
Inspect my local app in Safari and tell me why the layout is broken.
```

## Configuration fields

Each server supports:

- `command` — executable path to launch. Required.
- `args` — command arguments. Optional.
- `env` — environment variables to add or override for the server process. Optional.
- `timeout_seconds` — request timeout for MCP initialization, tool listing, and tool calls. Optional; defaults to 10 seconds.
- `enabled` — set to `false` to keep a server configured but disabled.

Example with an environment variable and custom timeout:

```json
{
  "mcpServers": {
    "example": {
      "command": "/usr/local/bin/example-mcp",
      "args": ["--stdio"],
      "env": { "EXAMPLE_MODE": "local" },
      "timeout_seconds": 20
    }
  }
}
```

## Notes and limitations

- Kward supports local stdio MCP servers and exposes their tools to the model.
- It does not support MCP resources, prompts, sampling, or Streamable HTTP.
- MCP tool results are returned to the model as text. Structured content is included as JSON. Image, audio, and resource results are summarized as placeholders.
- MCP servers can expose sensitive local application state. Only configure servers you trust, especially browser automation servers that can read page content or screenshots.
