# Extensibility

Kward can be customized at several levels:

- `PRINCIPLES.md` for global coding principles, plus workspace `AGENTS.md` for repository rules.
- Prompt templates for reusable slash-command prompts.
- Skills for reusable agent instructions the model can load on demand.
- Personas for assistant personality and communication style.
- Plugins for trusted Ruby extensions that add commands, footer UI, prompt context, transcript-event observers, and RPC-visible behavior.

Prompts, skills, personas, and config-directory `PRINCIPLES.md` live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead. Config-directory `AGENTS.md` remains supported as a legacy alias.

Plugins are different: user plugins are loaded only from `~/.kward/plugins`, regardless of `KWARD_CONFIG_PATH` or the current project directory. See the dedicated [Plugins guide](plugins.md).

## Which extension point should I use?

- Use config-directory `PRINCIPLES.md` for global coding principles, review expectations, or workflow guidance.
- Use workspace `AGENTS.md` for repository-specific rules and conventions.
- Use prompt templates when you want reusable slash commands such as `/plan <task>` or `/review <diff>`.
- Use skills when you want reusable instructions that Kward can load only when a task needs them.
- Use personas when you want to change tone, role, or communication style.
- Use plugins when you need Ruby code to run locally, add commands, observe transcript events, or integrate with another tool.

The optional starter pack installs a useful base `PRINCIPLES.md` and prompt templates. You can install it with:

```bash
kward init
```

## Agent instructions

Kward separates repository guidance from workspace-specific agent personality.

- Config-directory `PRINCIPLES.md`: global coding guidance appended to Kward's built-in system instructions when present. Config-directory `AGENTS.md` is still read as a legacy alias when `PRINCIPLES.md` is absent.
- Workspace `AGENTS.md`: repository guidance available from the active workspace root when present.

Use these files for engineering instructions such as coding rules, project conventions, testing requirements, review expectations, and workflow guidance. Avoid putting personality, roleplay, or communication style there; configure those as personas instead.

By default, workspace `AGENTS.md` is represented by a compact read-when-relevant instruction instead of injecting the full file into every request. Set `enforce_workspace_agents_file` to `true` if you need the full workspace file injected directly. Prompt files are skipped with a warning if they exceed 32 KiB.

## Prompt templates

Prompt templates create user-invocable slash commands for reusable prompts.

Create a template at:

```text
<config-dir>/prompts/<command>.md
```

For example, `prompts/plan.md` becomes `/plan` in interactive mode. Templates support `$ARGUMENTS`, replaced by the text after the command.

Built-in commands such as `/exit`, `/new`, `/resume`, `/name`, `/clone`, `/export`, `/redraw`, and `/status` are reserved.

Example prompt template:

```markdown
---
description: Create an implementation plan.
argument-hint: <task>
---

Plan this implementation request:

$ARGUMENTS
```

## Skills

Skills are reusable instruction packs the assistant can load when a task matches their description. They are useful when an instruction is too specific to include in every conversation, but important enough to keep around.

Create a skill at:

```text
<config-dir>/skills/<skill-name>/SKILL.md
```

A skill is listed in the system instructions by its frontmatter `name` and `description`. The assistant can then call `read_skill` to load `SKILL.md` or related files inside that skill folder.

Example skill:

```markdown
---
name: planner
description: Helps plan implementation work.
---

# Planner

Use this when planning a code change.
```

## Personas

Personas configure personality, role, and communication style without modifying repository files. New configs include a single active `kward` character by default; edit or remove `personas.default` to change the first-run experience. `personas.crew` is still accepted as an alias for `personas.characters`.

A small persona config looks like this:

```json
{
  "personas": {
    "characters": [
      {
        "key": "kward",
        "label": "Kward",
        "instruction": "Be concise, practical, and friendly. Prefer small, safe changes."
      }
    ],
    "default": "kward"
  }
}
```

You can also target personas by workspace, model, reasoning effort, time of day, or weekday:

```json
{
  "personas": {
    "characters": [
      {
        "key": "reviewer",
        "label": "Reviewer",
        "instruction": "Be skeptical and focus on correctness, tests, and maintainability."
      },
      {
        "key": "coach",
        "label": "Coach",
        "instruction": "Explain tradeoffs and teach as you go."
      }
    ],
    "default": "reviewer",
    "workspaces": {
      "/Users/kwood/Repositories/github.com/kaiwood/tauren": "coach"
    },
    "models": {
      "gpt-5.5": "reviewer"
    },
    "persona_modifiers": {
      "reasoning": {
        "high": "Think strategically before answering."
      },
      "suffix": "Act like it."
    }
  }
}
```

Persona evaluation order is:

1. `personas.default`
2. Matching `personas.workspaces` entry, using normalized workspace paths
3. Matching `personas.models` entry for the current model
4. Matching `persona_modifiers.reasoning` entry for the current reasoning effort
5. Matching `persona_modifiers.time_of_day` entry for local time: `morning` 05:00-10:59, `before_lunch` 11:00-11:59, `late_evening` 21:00-04:59
6. Matching `persona_modifiers.weekday` entry for the local weekday
7. `persona_modifiers.suffix`

Prompt assembly order is:

1. Kward built-in base prompt
2. Config-directory `PRINCIPLES.md` or legacy `AGENTS.md`
3. Evaluated persona text
4. Plugin prompt context
5. Skills listing
6. Workspace `AGENTS.md` hint, or full contents when `enforce_workspace_agents_file` is `true`

If no persona entries match, Kward simply omits that part. Conversation compaction uses a neutral prompt without workspace personality, so summaries stay continuation-focused and machine-oriented.

## Plugins

Plugins are Kward's trusted Ruby extension layer. Use them when you need behavior rather than just instructions or reusable prompts.

Plugins can add:

- slash commands,
- one custom terminal footer,
- prompt context,
- live transcript-event observers,
- command behavior exposed to RPC clients.

Plugin files live in:

```text
~/.kward/plugins/*.rb
```

See [Plugins](plugins.md) for the full plugin API, examples, and security model.
