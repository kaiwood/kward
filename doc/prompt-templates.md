# Prompt templates

Prompt templates turn a repeated request into a slash command. Keep one when you regularly ask Kward to plan before coding, investigate without changing files, or review a particular part of a project in the same way.

Templates are reusable **user prompts**, not always-on instructions. Kward expands the selected template when you run its slash command, then sends the expanded text as your request.

Use [skills](skills.md) for task guidance the model can load when relevant, `PRINCIPLES.md` for preferences that apply broadly, and `AGENTS.md` for repository rules.

## Create a template

By default, put one Markdown file per command in:

```text
~/.kward/prompts/
```

For example, create `~/.kward/prompts/review.md`:

```markdown
---
description: Review a change for correctness.
argument-hint: <focus>
---

Review the current diff for correctness, tests, and maintainability.
Focus on: $ARGUMENTS
Do not edit files; report findings first.
```

Restart Kward, or use `/reload` in an already-running session. The filename becomes the command name:

```text
/review authentication edge cases
```

Kward expands `$ARGUMENTS` everywhere it appears in the body with the text after `/review`. In this example, the model receives `Focus on: authentication edge cases`. If the template does not contain `$ARGUMENTS`, supplied arguments are not added automatically.

The `description` and `argument-hint` frontmatter fields are optional, but useful: Kward shows them in slash-command completion. The rest of the file is the prompt body. Add as much Markdown structure and instruction text as the workflow needs.

## Naming and discovery

Kward reads `*.md` files directly inside the prompts directory, in filename order. It ignores subdirectories. A filename must produce a command containing only letters, numbers, `_`, and `-`, and must begin with a letter or number:

```text
~/.kward/prompts/
├── review.md          # /review
├── release-check.md   # /release-check
└── api_v2.md          # /api_v2
```

A template cannot replace a built-in slash command such as `/settings`, `/skill`, or `/reload`; Kward warns and skips it. It also warns and skips files with invalid Markdown frontmatter or command names.

`~/.kward/prompts` is the default. When `KWARD_CONFIG_PATH` points to another config file, templates live in the `prompts/` directory beside that file instead. See [Configuration](configuration.md#Config_directory).

## Starter templates from `kward init`

After installing Kward, run:

```bash
kward init
```

The starter pack downloads template files into `~/.kward/prompts/` without overwriting files that already exist. It currently installs these four commands:

| Command | Use it for | What it asks Kward to do |
| --- | --- | --- |
| `/plan <task-or-change>` | Agree on an approach before coding | Clarify important requirements, produce a concise plan, and wait for confirmation before implementation. |
| `/investigate <bug-or-behavior>` | Diagnose a bug or surprising result | Gather evidence, identify the root cause or strongest hypothesis, suggest the smallest safe fix, and make no edits. |
| `/research <question-or-topic>` | Answer a question that needs current or external evidence | Prefer primary sources, separate facts from recommendations, cite sources and caveats, and make no changes. |
| `/codebase-review [scope-or-focus]` | Assess a repository or area for practical cleanup | Report concrete maintainability, correctness, duplication, ownership, testing, and hot-path findings without refactoring. |

For example:

```text
/plan Add rate limiting to the public API
/investigate The session picker occasionally shows the wrong title
/research Which OAuth scopes does this provider require?
/codebase-review lib/kward/model
```

The starter templates deliberately favor report- or plan-first workflows. They do not make Kward edit files until you follow up with an explicit implementation request. Edit the installed files to fit your own process, or add new files alongside them.

`kward init` also installs a base `PRINCIPLES.md` and starter skills. It needs network access to fetch the versioned [starter pack](https://github.com/kaiwood/kward-starter-pack) and leaves existing destination files untouched.

## Practical patterns

Keep templates specific enough to set a workflow, but short enough that the request remains easy to adapt. For example, a release-check prompt might take a version as an argument:

```markdown
---
description: Prepare release notes and verification for a version.
argument-hint: <version>
---

Prepare the release checklist for version $ARGUMENTS.
Inspect the changelog and version files. Do not publish or tag a release.
```

Then run:

```text
/release-check 1.4.0
```

Templates only expand text; they do not execute local code, grant permissions, or bypass Kward's tool and workspace safeguards.
