# API reference

Kward's generated Ruby API documentation is mainly for contributors, plugin authors, tool authors, and people building RPC or editor integrations.

If you use Kward from the terminal, start with the [user guides](file.README.html#Documentation) instead. The API reference exposes many internal classes because it is generated from the source tree; not every documented class is a stable extension API.

## Start here

- [Classes and modules](class_list.html): searchable index of generated Ruby constants.
- [Methods](method_list.html): searchable index of generated Ruby methods.
- [Files](file_list.html): generated file index.
- [Top-level Kward namespace](Kward.html): root namespace for the generated reference.

## Start by role

### Plugin authors

Use plugins when you need trusted local Ruby code for slash commands, prompt context, footer UI, transcript events, or RPC-visible commands.

Read first:

- [Plugins](plugins.md)
- [Extensibility](extensibility.md)

Generated entry points:

- [`Kward.plugin`](Kward.html#plugin-class_method)
- [`Kward::PluginRegistry`](Kward/PluginRegistry.html)
- [`Kward::PluginRegistry::DSL`](Kward/PluginRegistry/DSL.html)
- [`Kward::PluginRegistry::Context`](Kward/PluginRegistry/Context.html)

### Tool authors and contributors

Built-in tools are Ruby classes registered with Kward's tool registry. They expose schemas to the model and execute bounded local operations.

Read first:

- [Usage](usage.md#Workspace_tools)
- [Web search](web-search.md)
- [Code search](code-search.md)

Generated entry points:

- [`Kward::Tools`](Kward/Tools.html)
- [`Kward::Tools::Base`](Kward/Tools/Base.html)
- [`Kward::ToolRegistry`](Kward/ToolRegistry.html)

These pages document the schema and dispatch contract used by built-in tools. Kward does not yet provide a plugin DSL for registering arbitrary model-callable tools; contributors add them through the built-in registry and keep schemas, validation, docs, and tests aligned.

### RPC and frontend authors

The RPC protocol is the supported integration surface for UI clients. Prefer the protocol guide before reading implementation classes.

Read first:

- [RPC protocol](rpc.md)

Generated entry points:

- [`Kward::RPC`](Kward/RPC.html)
- [`Kward::RPC::Server`](Kward/RPC/Server.html)
- [`Kward::RPC::SessionManager`](Kward/RPC/SessionManager.html)
- [`Kward::RPC::ToolEventNormalizer`](Kward/RPC/ToolEventNormalizer.html)

### Prompt, skill, and configuration contributors

Prompt templates, skills, personas, and project instructions are user-facing extension points. Prefer the guides for supported behavior, then use the API reference to inspect implementation details.

Read first:

- [Extensibility](extensibility.md)
- [Personas](personas.md)
- [Configuration](configuration.md)

Generated entry points:

- [`Kward::Prompts`](Kward/Prompts.html)
- [`Kward::Prompts::Templates`](Kward/Prompts/Templates.html)
- [`Kward::Skills`](Kward/Skills.html)
- [`Kward::Skills::Registry`](Kward/Skills/Registry.html)
- [`Kward::ConfigFiles`](Kward/ConfigFiles.html)

The generated comments focus on these supported extension boundaries rather than trying to make every internal orchestration helper public. When a generated method lacks guide coverage, treat it as internal unless the page explicitly marks it as a public API.

## Public API expectations

Kward is still evolving. The generated reference is useful for understanding the codebase, but it should not be read as a promise that every class, method, or constructor is public and stable.

Prefer the documented guides for supported extension behavior. Use generated class and method pages when you need implementation detail, are contributing to Kward itself, or are coordinating a frontend integration with the current codebase.

As a rule of thumb:

- Guide-documented behavior is the supported user-facing surface.
- Plugin DSL methods are intended extension points.
- RPC JSON-RPC methods documented in [RPC protocol](rpc.md) are the integration contract for frontend clients.
- Generated classes without guide coverage may be internal implementation details.
