# Extensibility

Prompts and skills can live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead. Plugins are different: user plugins are loaded only from `~/.kward/plugins`, regardless of `KWARD_CONFIG_PATH` or the current project directory.

## Agent instructions

Kward separates repository guidance from workspace-specific agent personality.

- Config-directory `AGENTS.md`: global coding guidance appended to Kward's built-in system instructions when present.
- Workspace `AGENTS.md`: repository guidance loaded from the active workspace root when present.

Use `AGENTS.md` for engineering instructions such as coding rules, project conventions, testing requirements, review expectations, and workflow guidance. Avoid putting personality, roleplay, or communication style there; configure those as workspace system prompts instead.

Workspace `AGENTS.md` is injected once when a conversation starts. Kward refreshes it only when the file changes or when the agent edits the workspace `AGENTS.md`.

## Workspace system prompts

Workspace-specific system prompts configure personality, role, and communication style without modifying repository files. Add them to `config.json` under `workspaces`, keyed by workspace root:

```json
{
  "workspaces": {
    "/Users/kwood/Repositories/github.com/kaiwood/kward": {
      "system_prompt": "Always speak like the Computer on the USS Tauren, a famous Federation exploration vessel."
    },
    "/Users/kwood/Repositories/github.com/kaiwood/tauren": {
      "system_prompt": "Speak like a highly decorated Klingon officer serving aboard the USS Tauren."
    }
  }
}
```

Prompt assembly order is:

1. Kward built-in base prompt
2. Config-directory `AGENTS.md`
3. Workspace `system_prompt`
4. Skills listing
5. Workspace `AGENTS.md`

If a workspace has no configured `system_prompt`, Kward preserves existing behavior and simply omits that part. Conversation compaction uses a neutral prompt without workspace personality, so summaries stay continuation-focused and machine-oriented.

## Skills

- `skills/<skill-name>/SKILL.md`: listed in the system instructions by frontmatter `name` and `description`. The assistant can call `read_skill` to load `SKILL.md` or related files inside that skill folder.

Example skill:

```markdown
---
name: planner
description: Helps plan implementation work.
---

# Planner

Use this when planning a code change.
```

## Prompt templates

- `prompts/<command>.md`: user-invocable prompt templates available as interactive slash commands, such as `/plan fix bug`. Prompt templates support `$ARGUMENTS`, replaced by the text after the command. Built-in commands like `/exit`, `/new`, `/resume`, `/name`, `/clone`, `/export`, `/redraw`, and `/status` are reserved.

Example prompt template:

```markdown
---
description: Create an implementation plan.
argument-hint: <task>
---

Plan this implementation request:

$ARGUMENTS
```

## Plugins

- `~/.kward/plugins/*.rb`: trusted top-level Ruby plugin files loaded from the user plugin directory only. Kward does not load plugins from the project/workspace directory or from a `KWARD_CONFIG_PATH` directory. If a custom config directory has a legacy `plugins` folder, Kward warns and ignores it. Plugins execute as local Ruby code in the Kward process, so install only plugins you trust.
- Plugins can register slash commands and one custom footer renderer. Built-in commands and prompt-template commands are reserved.
- Plugin slash commands are available in interactive slash completion and through RPC `commands/list`. RPC clients can execute plugin commands with `commands/run`.
- Plugin command and footer contexts expose read-only transcript access through `ctx.transcript.messages`, plus session metadata and `ctx.say` for command output.

Example plugin:

```ruby
Kward.plugin do |plugin|
  plugin.command "last-message", description: "Show transcript size" do |_args, ctx|
    ctx.say("Messages: #{ctx.transcript.messages.length}")
  end

  plugin.footer do |ctx|
    "#{ctx.session_name || 'unnamed'} • #{ctx.transcript.messages.length} messages"
  end
end
```
