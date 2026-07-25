# Context tools

Context tools help Kward load reusable instructions, recover compacted tool output, and ask structured clarification questions. These tools usually run in the background as part of a turn rather than as commands you type directly.

## `read_skill`

`read_skill` loads configured skill instructions when a task matches a known skill.

Arguments:

- `name`: skill name.
- `path`: optional path inside the skill, default `SKILL.md`.

Skill file paths must be relative and stay inside the skill folder. Absolute paths and path traversal are rejected. Files larger than 100 KB are also rejected.

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

Kward may compact large shell, search, fetch, or file outputs before sending them back to the model. The compacted result includes enough summary to continue, plus an artifact id when the original output is worth preserving. If later work needs details, Kward can retrieve a focused slice of the original output instead of asking the tool to repeat the whole operation, including after resuming a saved session that contains the original tool execution record.

This saves tokens in two ways:

- repeated large outputs are not resent to the model,
- follow-up reads can target only matching lines or a bounded line range.

When a `query` is provided, matching lines are returned with 1-indexed line numbers prefixed. The result includes a header with the artifact id, query, and line range. When there are more results than the limit, a continuation notice with the next `offset` is included.

For details on how tool outputs are compacted and when artifacts are created, see [Agent tools](agent-tools.md).

## `ask_user_question`

`ask_user_question` asks one to four structured clarification questions through an interactive frontend.

Arguments:

- `questions`: array of one to four questions.
- each question has:
  - `header`: short label shown in the overlay,
  - `question`: the question text,
  - `options`: two to four selectable answers with `label` and `description`.

Constraints:

- `multiSelect` is unsupported; questions are single-select.
- `preview` on options is unsupported.
- Each option requires both `label` and `description`.
- In terminal use, the picker also accepts custom typed answers beyond the provided options, so the user is not limited to the listed choices.

The question picker is available only in frontends that support structured questions. In the terminal, it lets Kward ask a concise multiple-choice question instead of guessing. RPC clients receive the same flow through UI events; see the [RPC question bridge](rpc.md) for notification and response details.

Good uses:

- choosing between safe implementation approaches,
- confirming an ambiguous scope,
- selecting a provider, model, or behavior when no default is obvious.

Structured questions are most useful when the answer would materially change the implementation or avoid a risky assumption—not for every small uncertainty.

## Availability

`Kward::ToolRegistry` only advertises context tools when they are usable:

- `read_skill` requires configured skills,
- `ask_user_question` requires frontend support,
- `retrieve_tool_output` is available in normal sessions so compacted artifacts can be inspected later.
