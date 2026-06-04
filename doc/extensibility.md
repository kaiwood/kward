# Extensibility

Prompt and skills can live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead.

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
4. Workspace `AGENTS.md`
5. Skills listing

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
