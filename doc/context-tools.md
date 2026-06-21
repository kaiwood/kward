# Context tools

Context tools help Kward load reusable instructions, recover compacted tool output, and ask structured clarification questions. These tools usually run in the background as part of a turn rather than as commands you type directly.

## `read_skill`

`read_skill` loads configured skill instructions when a task matches a known skill.

Arguments:

- `name`: skill name.
- `path`: optional path inside the skill, default `SKILL.md`.

Skills are reusable instruction bundles stored in the Kward config directory. Kward advertises available skills by name and description, then reads the full skill only when it becomes relevant. That saves tokens because every skill does not need to be injected into every request.

Typical uses:

- loading test-writing guidance before changing tests,
- loading security guidance before editing auth, secrets, cookies, uploads, or personal data handling,
- loading language-specific style guidance before refactoring code.

See [Extensibility](extensibility.md) for how skills fit with prompts, personas, and project instructions.

## `retrieve_tool_output`

`retrieve_tool_output` reopens original output that was compacted out of the model-facing context.

Arguments:

- `id`: tool output artifact id, such as `toolout_abc123`.
- `offset`: optional 1-indexed line offset.
- `limit`: optional maximum lines to return, default 120.
- `query`: optional case-insensitive text search within the original output.

Kward may compact large shell, search, fetch, or file outputs before sending them back to the model. The compacted result includes enough summary to continue, plus an artifact id when the original output is worth preserving. If later work needs details, Kward can retrieve a focused slice of the original output instead of asking the tool to repeat the whole operation.

This saves tokens in two ways:

- repeated large outputs are not resent to the model,
- follow-up reads can target only matching lines or a bounded line range.

## `ask_user_question`

`ask_user_question` asks one to four structured clarification questions through an interactive frontend.

Arguments:

- `questions`: array of one to four questions.
- each question has:
  - `header`: short label shown in the overlay,
  - `question`: the question text,
  - `options`: two to four selectable answers with labels and descriptions.

This tool is advertised only when the active frontend supports structured questions. In terminal use, it lets Kward ask concise multiple-choice questions instead of guessing requirements. In RPC clients, the same question flow is bridged through UI events.

Good uses:

- choosing between safe implementation approaches,
- confirming an ambiguous scope,
- selecting a provider, model, or behavior when no default is obvious.

Kward should not use this tool for every small uncertainty. It is best when an answer materially changes the implementation or avoids a risky assumption.

## Availability

`Kward::ToolRegistry` only advertises context tools when they are usable:

- `read_skill` requires configured skills,
- `ask_user_question` requires frontend support,
- `retrieve_tool_output` is available in normal sessions so compacted artifacts can be inspected later.
