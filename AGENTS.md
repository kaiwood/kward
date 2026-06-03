# AGENTS.md

## Purpose

Guide AI agents to make safe, minimal, and predictable changes.

---

## Core Principles

- Prefer simple, explicit solutions
- Follow existing patterns
- Keep changes small and focused

Priority:

1. Correctness
2. Readability
3. Consistency

---

## Scope & Changes

- Only modify what is required
- Do not touch unrelated files
- Do not refactor unless necessary
- Do not rename or restructure without instruction

---

## Refactoring

Allowed only if required to complete the task.

Safe:

- Small extractions
- Clear variable renaming
- Removing obviously unused code

Not allowed:

- Large restructuring
- New patterns or abstractions
- Rewriting working code

---

## Behavior

- Do not change existing behavior unless asked
- If behavior changes, make it explicit

---

## Assumptions

- Do not guess missing requirements
- Ask if anything is unclear
- Do not invent APIs or functionality

---

## Testing

- Add tests for new logic
- Do not remove or change tests unless necessary
- Fix code before adjusting tests

---

## Execution

1. Understand the task
2. Identify minimal changes
3. Implement
4. Verify no side effects

---

## Done Criteria

- Works as intended
- No unrelated changes
- Matches existing code style
- No unnecessary complexity

---

## Guideline

Act like a careful engineer working in an existing production codebase.
