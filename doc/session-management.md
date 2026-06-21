# Session management

Sessions are Kward's way of keeping real work alive across time. An interactive chat is not just a scrollback buffer: it is saved as a session with messages, tool calls, tool results, compaction checkpoints, branches, and enough metadata for Kward to resume the work later.

Think of sessions as **context management**. They let you decide which conversation context Kward should use next.

Think of rewinding and forking as **context time travel**. You can go back to an earlier prompt, try a different path, and keep both versions instead of losing the original work.

## Where sessions live

Interactive sessions are saved under:

```text
~/.kward/sessions/
```

Sessions are scoped to the workspace. If you run Kward in two different projects, each project has its own recent sessions.

One-shot prompts such as `kward "Explain this project"` do not use session history. Start interactive Kward when you want ongoing context:

```bash
cd ~/code/project
kward
```

## A normal session workflow

Start a chat and give it a useful name:

```text
/rename oauth cleanup
```

Work normally:

```text
Find the OAuth callback code and explain how errors are handled.
Add a focused test for the missing expired-token case.
Run the related test file.
```

Leave when you are done for now:

```text
/exit
```

Later, resume the work:

```text
/sessions
```

The session picker shows recent sessions for the current workspace. Choose one to restore its transcript and continue with the same context.

`/resume` is an alias for `/sessions`.

## The sessions picker

Open it with:

```text
/sessions
```

Inside the picker you can:

| Key | Action |
| --- | --- |
| `Enter` | resume the highlighted session. |
| `r` | rename the highlighted session. |
| `c` | clone the highlighted session. |
| `f` | fork the highlighted session from an earlier prompt. |
| `d d` | delete the highlighted session after confirmation. |

Use names generously. A session named `oauth cleanup` or `release checklist` is much easier to find later than a timestamp.

## Clone a session

Clone when you want an exact copy of the current conversation and then continue in a separate branch.

From inside the active session:

```text
/clone
```

Or from `/sessions`, highlight a session and press `c`.

A clone keeps the same conversation so far, but future messages are written to the new session file. The original session remains unchanged.

Good uses:

- try a risky refactor while preserving the safe version,
- continue a review with a different strategy,
- keep a checkpoint before asking Kward to make broad changes,
- split one investigation into two independent paths.

Mental model: **clone copies the whole timeline and starts a new future from now.**

## Fork from an earlier prompt

Fork when you want to go back to a specific user prompt and create a new independent session from before that prompt.

From inside the active session:

```text
/fork
```

Or from `/sessions`, highlight a session and press `f`.

Kward shows earlier user prompts. Choose the prompt where the new path should begin. Kward creates a new session containing the conversation before that prompt, then pre-fills the selected prompt so you can edit or resubmit it.

Good uses:

- you asked the wrong question and want to rephrase it,
- Kward solved the right problem in the wrong style,
- you want to try a smaller implementation after a larger one,
- you want two alternative designs starting from the same point.

Mental model: **fork cuts the timeline before a selected prompt and starts a new session there.**

## Rewind within the current session

Rewind is the fastest way to revisit an earlier prompt in the current session:

```text
/rewind
```

Kward shows previous user prompts from the active branch. Choose one, edit it if needed, and continue from that point. Future messages become a new branch in the same session history.

Use rewind when you are still working inside one session and want to quickly try a different direction.

Good uses:

- undo a bad turn without throwing away the whole session,
- retry an earlier request with tighter instructions,
- branch from a known-good point after a tool result revealed something new,
- jump back after realizing the current path is too broad.

When available, `/rewind` also offers a return option so you can go back to where you were before rewinding.

Mental model: **rewind moves the active point inside the same session timeline.**

## Inspect the full tree

Use `/tree` when you need the technical view of a session's history:

```text
/tree
```

The session tree includes more than the friendly `/rewind` list. It can show branches, assistant entries, tool calls, tool results, compaction checkpoints, and the current active leaf. Choose an entry to move the active session position there.

Most users should reach for `/rewind` first. Use `/tree` when you need to understand or navigate the full branching structure.

Good uses:

- inspect where a branch split,
- return to a specific tool-heavy checkpoint,
- understand what happened after multiple rewinds,
- navigate a long session with several alternative paths.

Mental model: **`/tree` is the map; `/rewind` is the friendly time machine.**

## Compact long sessions

Long sessions can outgrow the model's useful context window. Use compacting to keep going:

```text
/compact
```

You can add focus instructions:

```text
/compact preserve the API docs navigation decisions and current failing checks
```

Compaction summarizes older conversation into a checkpoint and keeps recent context active. Historical messages remain in the session file for audit, export, and tree navigation, but the live model context becomes smaller.

After compaction, Kward may need to re-read files before editing them again. That is normal: read-before-edit guardrails apply to the current live context.

Compaction is also context management. It trades detailed old conversation for a concise working summary so Kward can spend tokens on the next task.

## Export a session

Export when you want notes outside Kward:

```text
/export notes.md
```

Exports are useful for handoff notes, review summaries, release records, or saving a human-readable transcript before deleting old sessions.

## Which command should I use?

| Need | Use |
| --- | --- |
| Continue earlier work | `/sessions` or `/resume` |
| Give the current session a better name | `/rename <name>` |
| Keep the current state but try another future | `/clone` |
| Start a separate session from before an earlier prompt | `/fork` |
| Quickly retry an earlier prompt in this session | `/rewind` |
| Inspect or navigate the full branch structure | `/tree` |
| Reduce old context so a long session can continue | `/compact` |
| Save a readable transcript | `/export <path>` |

## Practical habits

- Rename sessions early when work becomes important.
- Clone before risky or broad changes.
- Fork when the earlier prompt was the wrong starting point.
- Rewind when you want a fast alternate attempt inside the same session.
- Use `/tree` only when the friendly commands are not enough.
- Compact when the conversation gets long, but keep the focus instruction specific.

Sessions make Kward less like a single chat box and more like a workspace timeline. You can preserve context, branch it, compress it, and return to it when the work needs another pass.
