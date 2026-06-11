# Extensibility

Kward can be customized at several levels:

- `AGENTS.md` for coding guidance and repository rules.
- Personas for assistant personality and communication style.
- Skills for reusable agent instructions the model can load on demand.
- Prompt templates for reusable slash-command prompts.
- Plugins for trusted Ruby extensions that add commands, footer UI, prompt context, transcript-event observers, and RPC-visible behavior.

Prompts, skills, personas, and config-directory `AGENTS.md` live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead.

Plugins are different: user plugins are loaded only from `~/.kward/plugins`, regardless of `KWARD_CONFIG_PATH` or the current project directory. See the dedicated [Plugins guide](plugins.md).

## Agent instructions

Kward separates repository guidance from workspace-specific agent personality.

- Config-directory `AGENTS.md`: global coding guidance appended to Kward's built-in system instructions when present.
- Workspace `AGENTS.md`: repository guidance loaded from the active workspace root when present.

Use `AGENTS.md` for engineering instructions such as coding rules, project conventions, testing requirements, review expectations, and workflow guidance. Avoid putting personality, roleplay, or communication style there; configure those as personas instead.

Workspace `AGENTS.md` is injected once when a conversation starts. Kward refreshes it only when the file changes or when the agent edits the workspace `AGENTS.md`. Config-directory and workspace `AGENTS.md` files are skipped with a warning if they exceed 32 KiB, because they are injected into every model request.

## Personas

Personas configure personality, role, and communication style without modifying repository files. Add them to `config.json` under `personas`:

```json
{
  "personas": {
    "crew": [
      {
        "key": "kward",
        "label": "Kward",
        "instruction": "You are an officer on board of the USS Tauren"
      },
      {
        "key": "computer",
        "label": "Computer",
        "instruction": "Always speak like the computer on the USS Tauren, a famous Federation exploration vessel."
      },
      {
        "key": "k-ward",
        "label": "K'warD",
        "instruction": "Speak like a highly decorated Klingon officer serving aboard the USS Tauren."
      }
    ],
    "default": "kward",
    "workspaces": {
      "/Users/kwood/Repositories/github.com/kaiwood/tauren": "computer"
    },
    "models": {
      "gpt-5.5": "k-ward"
    },
    "persona_modifiers": {
      "reasoning": {
        "low": "You have a Patrick Starfish like IQ.",
        "medium": "You are a competent Starfleet officer.",
        "high": "You are a highly intelligent strategist.",
        "xhigh": "You have an Albert Einstein level IQ."
      },
      "time_of_day": {
        "morning": "You are sleepy and in need of coffee.",
        "before_lunch": "You are hungry and slightly impatient.",
        "late_evening": "You are tired and occasionally yawn."
      },
      "weekday": {
        "monday": "You have a mild hangover from the weekend.",
        "saturday": "You are annoyed because you expected shore leave.",
        "sunday": "You are melancholic about Monday approaching."
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
2. Config-directory `AGENTS.md`
3. Evaluated persona text
4. Plugin prompt context
5. Skills listing
6. Workspace `AGENTS.md`

If no persona entries match, Kward simply omits that part. Conversation compaction uses a neutral prompt without workspace personality, so summaries stay continuation-focused and machine-oriented.

## Skills

Skills are reusable instruction packs the assistant can load when a task matches their description.

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
