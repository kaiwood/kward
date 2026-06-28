# Extensibility

Kward can be customized without changing its source code. Use extensibility when you want Kward to follow your conventions, repeat common prompts, or add local behavior.

Start simple. Most users only need `PRINCIPLES.md`, workspace `AGENTS.md`, and maybe a prompt template.

## Choose the right extension point

| Need | Use |
| --- | --- |
| Global coding preferences | `~/.kward/PRINCIPLES.md` |
| Repository-specific rules | `<workspace>/AGENTS.md` |
| Reusable slash prompts | prompt templates |
| Task-specific reusable instructions | skills |
| Different tone or role | [personas](personas.md) |
| Local Ruby behavior or integrations | plugins |

Install the starter pack for a useful starting point:

```bash
kward init
```

## Global instructions: `PRINCIPLES.md`

Use this for preferences you want in most projects:

```markdown
Prefer small, focused changes.
Add tests for new behavior.
Do not refactor unrelated code.
Explain risky assumptions before editing.
```

Default location:

```text
~/.kward/PRINCIPLES.md
```

If `KWARD_CONFIG_PATH` is set, `PRINCIPLES.md` lives beside that config file.

If `PRINCIPLES.md` is absent, Kward also reads `~/.kward/AGENTS.md` (or the equivalent beside a custom config path) as a legacy alias. New setups should use `PRINCIPLES.md`. See [Configuration](configuration.md) for details.

## Project instructions: `AGENTS.md`

Put repository-specific rules in the workspace root:

```text
my-project/AGENTS.md
```

Good examples:

```markdown
Run tests with `bundle exec rake test`.
Use Minitest, not RSpec.
Do not change generated files under `schema/`.
Update CHANGELOG.md for user-visible changes.
```

Use `AGENTS.md` for project facts and engineering rules. Do not put personality or roleplay instructions there; use [personas](personas.md) for tone.

By default, Kward adds a compact instruction telling the model that `AGENTS.md` exists and should be read when relevant. Set `enforce_workspace_agents_file: true` only if you want the full file injected every time. See [Configuration](configuration.md) for details.

## Prompt templates

Use prompt templates when you repeatedly type the same kind of request.

Create:

```text
~/.kward/prompts/review.md
```

Example:

```markdown
---
description: Review a change for correctness.
argument-hint: <focus>
---

Review the current diff for correctness, tests, and maintainability.
Focus on: $ARGUMENTS
```

Then run inside Kward:

```text
/review auth edge cases
```

The `description` frontmatter field appears in the slash command list and completion overlay so you can find the template by purpose. `argument-hint` is shown as a usage hint. The `$ARGUMENTS` placeholder in the body is replaced with whatever you type after the command.

Prompt templates are best for reusable text. They do not run local code.

## Skills

Use skills for reusable instructions that should only be loaded for certain tasks.

Create:

```text
~/.kward/skills/testing/SKILL.md
```

Example:

```markdown
---
name: testing
description: Use when adding or changing tests.
---

Prefer focused tests near the changed behavior.
Do not weaken assertions to make tests pass.
```

Skills are listed to the model by name and description. When a task matches a skill, the model calls the `read_skill` tool to load the full `SKILL.md` instructions before proceeding.

Skills can also contain additional files alongside `SKILL.md`. The model can read them through `read_skill` with a relative `path` argument (for example, `path: examples.md`). Files must stay inside the skill folder; paths outside are rejected.

## Plugins

Use plugins when text instructions are not enough and you need Ruby code to run locally.

Plugins can add slash commands, prompt context, footer UI, transcript observers, and RPC-visible commands.

Plugin files live in:

```text
~/.kward/plugins/*.rb
```

Plugins are trusted local Ruby code. Install only plugins you trust. See [Plugins](plugins.md).

## Prompt assembly order

When Kward builds instructions for a turn, it combines roughly:

1. Kward's built-in operating instructions.
2. `PRINCIPLES.md`.
3. memory context (when memory is enabled and relevant).
4. selected persona.
5. plugin prompt context.
6. available skills list.
7. workspace `AGENTS.md` hint or full content.

If behavior seems surprising, inspect the assembled instructions:

```bash
kward sysprompt
```

Add `--raw` to print the raw system prompt content without section formatting, useful for piping to another tool:
