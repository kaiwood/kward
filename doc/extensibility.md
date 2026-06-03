# Extensibility

Prompt and skills can live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead.

## Agent instructions

- `AGENTS.md`: appended to Kward's built-in system instructions when present.

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
