# Skills

Skills are reusable instructions that Kward loads only when they are useful. They are good for workflows such as testing, code review, release checks, writing documentation, or working in a domain with specific rules.

Kward supports the Agent Skills folder format: each skill is a directory with a `SKILL.md` file. Kward shows the model only each skill's name and description at startup. The full instructions are loaded later, either when the model decides they match the task or when you activate the skill yourself.

## When to use a skill

Use a skill when you want specialized guidance that should not be in every prompt.

Good skill examples:

- testing practices for your project
- release checklist steps
- API review rules
- incident response workflow
- documentation style guidance
- domain-specific terminology and examples

Use `AGENTS.md` instead for repository-wide rules that should apply to almost every task. Use prompt templates when you want to expand a reusable user prompt with arguments.

## Create a skill

A minimal skill looks like this:

```text
~/.agents/skills/testing/SKILL.md
```

```markdown
---
name: testing
description: Use when adding or changing tests, fixing regressions, or verifying behavior.
---

Prefer focused tests near the changed behavior.
Do not weaken assertions to make tests pass.
Run the smallest relevant test first, then broaden if needed.
```

The `name` and `description` fields are required. The description matters: Kward puts it in the skill catalog so the model can decide when to load the skill.

Skill names should be lowercase letters, numbers, and hyphens, such as `testing`, `code-review`, or `release-checklist`.

## Capture a skill from a session

Use `/skill capture` after a useful session. Choose any saved session; Kward uses its active branch and asks your active model to draft a reusable `SKILL.md`. Review and edit the draft in the terminal editor, then save it explicitly. Captured skills always go to your personal Kward skill directory and are not activated automatically.

The draft request includes the complete persisted branch, including available raw tool output and saved session context. Treat it like any other model request: do not capture a session whose contents you are not willing to send to the active provider. Kward rejects a source that does not fit the active model context instead of silently truncating it.

If the reviewed name already exists, Kward requires an explicit overwrite confirmation. Activate a saved draft later with `/skill <name>`.

Pan provides the same saved-session picker and editable review flow. RPC clients use `skills/captureSessions`, `skills/captureDraft`, and `skills/saveCapturedDraft`; see the [RPC protocol](rpc.md).

## Skill locations

User-level skills are available in every project:

```text
~/.kward/skills/<name>/SKILL.md
~/.agents/skills/<name>/SKILL.md
```

Project-level skills live in the current workspace:

```text
<workspace>/.kward/skills/<name>/SKILL.md
<workspace>/.agents/skills/<name>/SKILL.md
```

The `.agents/skills` paths are the cross-client Agent Skills convention. Use them when you want skills to work across compatible agents.

Project skills require an explicit trust decision because repository-provided instructions may be untrusted. In the interactive TUI, Kward asks when it finds a new or changed project skill:

```text
Allow / Deny / Review
```

`Review` displays the bounded `SKILL.md` contents and lists referenced resources without executing them. Trust decisions are scoped to the current workspace and skill snapshot. A changed skill or newly added skill requires another decision. Use `/new` after changing trust for the active agent to rebuild.

You can inspect or manage the current workspace from the TUI:

```text
/skills status
/skills trust
/skills untrust
```

For non-interactive use, inspect or manage trust explicitly:

```bash
kward --working-directory /path/to/project skills status
kward --working-directory /path/to/project skills review
kward --working-directory /path/to/project skills trust
```

Trust records are stored in `~/.kward/trusted_project_skills.json`. The legacy global setting remains available:

```json
{
  "skills": {
    "trust_project": true
  }
}
```

In the interactive TUI, skipped or malformed skill diagnostics are shown as synchronized `Runtime>` messages so they do not interrupt screen rendering. Other interactive warnings use the same channel; non-interactive commands continue to report diagnostics on stderr.

## How Kward uses skills

Kward uses progressive loading:

1. At startup, Kward lists available skill names and descriptions in the system prompt.
2. When a task matches a skill, the model calls `read_skill` to load `SKILL.md`.
3. If the skill references supporting files, the model reads only the needed files.

You can also activate a skill explicitly:

```text
/skill testing
```

or:

```text
/skill:testing
```

Explicit activation loads the skill instructions into the current conversation without asking the model to infer that the skill is relevant.

Activated skills are preserved during context compaction, so Kward does not silently forget the workflow in a long session.

## Add supporting files

A skill can include extra files:

```text
~/.agents/skills/release-checklist/
├── SKILL.md
├── references/
│   └── versioning.md
├── scripts/
│   └── check_changelog.rb
└── assets/
    └── release-template.md
```

Example `SKILL.md`:

```markdown
---
name: release-checklist
description: Use when preparing a release, updating versions, or writing changelog entries.
---

Follow the release checklist:

1. Read `references/versioning.md`.
2. Confirm `CHANGELOG.md` has an Unreleased entry.
3. If needed, inspect `assets/release-template.md`.
4. Run `scripts/check_changelog.rb` before proposing the final release notes.
```

When Kward loads the skill, it lists bundled files under `references/`, `scripts/`, and `assets/` without reading all of them. The model can then request a specific file with `read_skill`, using a path relative to the skill directory.

For example, the model can call:

```json
{
  "name": "release-checklist",
  "path": "references/versioning.md"
}
```

Paths are constrained to the skill directory. Absolute paths and `..` traversal outside the skill are rejected.

## Discovery precedence

If multiple skills have the same `name`, Kward uses the first one in this order:

1. `<workspace>/.kward/skills`
2. `<workspace>/.agents/skills`
3. Kward config directory `skills` (`~/.kward/skills` by default, or beside `KWARD_CONFIG_PATH`)
4. `~/.agents/skills`

Shadowed skills are skipped with a warning. Rename one of the skills if you want both to be available.

## Optional metadata

Kward understands these optional `SKILL.md` frontmatter fields:

```yaml
license: MIT
compatibility: Requires git and Ruby.
metadata:
  author: example-team
  version: "1.0"
allowed-tools: Bash(git:*) Read
```

`allowed-tools` is parsed for compatibility with the Agent Skills format, but Kward does not currently use it to grant extra permissions. Treat skill scripts and instructions as trusted only when you trust their source.

## Troubleshooting

If a skill does not appear:

- Check that the file is named exactly `SKILL.md`.
- Check that `name` and `description` are present in frontmatter.
- Check that the directory name and skill name are sensible and unique.
- If it is a project skill, make sure project skills are trusted in `/settings`.
- Look for warnings about skipped, malformed, or shadowed skills.

If a skill activates but cannot read a supporting file, make sure the path is relative to the skill directory, for example:

```text
references/details.md
```

not:

```text
../other-skill/details.md
```
