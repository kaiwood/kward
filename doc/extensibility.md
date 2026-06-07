# Extensibility

Prompts and skills can live beside the config file. By default this is `~/.kward`; if `KWARD_CONFIG_PATH` is set, Kward uses that file's directory instead. Plugins are different: user plugins are loaded only from `~/.kward/plugins`, regardless of `KWARD_CONFIG_PATH` or the current project directory.

## Agent instructions

Kward separates repository guidance from workspace-specific agent personality.

- Config-directory `AGENTS.md`: global coding guidance appended to Kward's built-in system instructions when present.
- Workspace `AGENTS.md`: repository guidance loaded from the active workspace root when present.

Use `AGENTS.md` for engineering instructions such as coding rules, project conventions, testing requirements, review expectations, and workflow guidance. Avoid putting personality, roleplay, or communication style there; configure those as personas instead.

Workspace `AGENTS.md` is injected once when a conversation starts. Kward refreshes it only when the file changes or when the agent edits the workspace `AGENTS.md`.

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
4. Skills listing
5. Workspace `AGENTS.md`

If no persona entries match, Kward simply omits that part. Conversation compaction uses a neutral prompt without workspace personality, so summaries stay continuation-focused and machine-oriented.

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
