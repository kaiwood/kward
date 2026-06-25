# Changelog

All notable changes to Kward will be documented in this file.

## [Unreleased]

### Added

- Added a read-only TUI diff viewer from `/git`
- Added interactive plugin commands via `plugin.interactive_command` that take over the composer region with a Kward-driven canvas render loop
- Added `$` to the TUI, to open files with the new editor
- Added a builtin editor with 3 modes: moder, emacs and vibe.
- Added TUI composer `@` file mentions with a filterable project-file overlay and Tab completion.
- Added `/git` in the interactive TUI to review uncommitted changes and commit all workspace changes from an overlay.
- Added file-level stage/unstage toggling to the interactive `/git` overlay with `s` and Up/Down selection.
- Added a Git branch indicator to the TUI composer status, coloring it yellow when the working tree has uncommitted changes.
- Added persistent numbered TUI tabs for session-backed conversations
- Added experimental support for agent workers


### Changed

- Changed picker titles and selected rows to use the quieter primary-green border color instead of the bright accent green.

### Fixed

- Added vibe-mode editor `zz`, `zt`, and `zb` viewport positioning commands.
- Fixed vibe-mode editor handling for CSI-u encoded Ctrl+f/Ctrl+b/Ctrl+d/Ctrl+u/Ctrl+e/Ctrl+y page and scroll shortcuts.
- Fixed TUI tab restoration so empty tabs whose unused session files were cleaned up are restored as new sessions instead of being dropped and shifting later sessions into the wrong tab.
- Fixed generated documentation pages with a table of contents so code blocks no longer leave a large vertical gap beside the TOC.
- Fixed the editor vibe-mode `H`, `L`, and `M` screen-position keys (and page up/down, half-page, and scroll) so they use the actual rendered viewport height instead of a stale capped heuristic, making them respect the current window height. Also fixed `H`/`L`/`M` in soft-wrap mode so they translate visual-row offsets to logical lines instead of scrolling the viewport.

## [0.71.0] - 2026-06-21

### Fixed

- Fixed generated YARD guide links so doc-to-doc Markdown links point at the generated `file.*.html` pages.
- Fixed web-tool results with BINARY/ASCII-8BIT response bodies so RPC tool events and TUI rendering receive UTF-8-safe content.

### Changed

- Changed transcript rendering so assistant, reasoning, and tool output starts on the same line as its label.
- Changed the interactive startup screen to an info block.”
- Changed shell command output capture to allow larger raw output for Kward's own compactor, preserving stdout/stderr structure and test failure summaries before model-context trimming.
- Tightened the built-in system prompt wording to reduce repeated instruction tokens.
- Changed generated runtime system prompts to use a stable timestamp anchor so time-based persona modifiers do not churn provider cache prefixes each turn.
- Changed tool schema properties to be emitted in deterministic key order for more stable provider request payloads.
- Changed large source-file reads to return an outline plus a short preview before requiring offset/limit continuation.
- Changed large search and fetched-content tool results to preserve file, line, URL, and heading anchors during model-context compaction.
- Changed large tool results to be compacted before they enter model context while preserving full originals in session tool-execution records, reusing existing artifact ids for repeated outputs, avoiding storage for verbatim outputs, preserving short errors exactly, reverting automatically when compaction would not reduce context, and teaching conversation compaction to preserve tool artifact ids.
- Changed model context-window resolution to prefer cached OpenRouter metadata, infer matching provider models from that metadata when possible, and use conservative fallbacks for unknown selected models.
- Updated the authentication guide to describe model picker selection and OpenRouter model cache refresh/list commands.

### Removed

- Removed the `banner.enabled` config setting and `/settings` toggle for hiding the interactive startup screen.
- Removed the generated table of contents and source-checkout launch snippet from the RPC protocol guide.

### Added

- Added a Sessions guide covering saved sessions, cloning, forking, rewinding, tree navigation, compaction, and exports.
- Added Agent Tools documentation pages covering workspace tools, context tools, and token-saving tool-output behavior.
- Added an API reference overview page and API docs navigation dropdown for generated Ruby indexes and key namespaces.
- Added Turbolinks-style navigation to the generated documentation site for same-origin HTML links.
- Added a `docs:check` Rake task and HTMLProofer development dependency for checking generated documentation links, images, and scripts.
- Added a `docs:serve` Rake task and WEBrick development dependency for previewing the built YARD documentation site locally with automatic rebuilds.
- Added optional `compaction` telemetry logging for tool-output context savings.
- Added a `summarize_file_structure` tool for compact source-file outlines before reading full files.
- Added a `retrieve_tool_output` tool for inspecting original outputs that were compacted out of model context.
- Added `kward openrouter refresh` and `kward openrouter list` for caching key-scoped text-capable OpenRouter models in the Kward cache directory.
- Added `/fork` for creating a new session from an earlier prompt and pre-filling that prompt for editing.
- Added `f` in the `/sessions` picker to open the fork prompt selector for the selected session.
- Added `/rename <name>` for renaming the current interactive session.
- Added `r` in the `/sessions` picker to rename the selected session without closing the picker.
- Added `c` in the `/sessions` picker to clone the selected session and open the new clone, with a cloning spinner while it runs.
- Added `d d` in the `/sessions` picker to delete the selected session after an inline confirmation.

## [0.70.0] - 2026-06-19

### Added

- Added `/rewind` for revisiting earlier user prompts and continuing from there as a branch, while `/tree` remains the advanced full session tree navigator.

### Changed

- Changed TUI selection search to start only after pressing `/`, hiding the composer cursor until search mode is active and supporting shell-style editing keys while searching.
- Changed the `/sessions` picker to show right-aligned relative timestamps like `/rewind`.
- Changed TUI list navigation to keep long `/sessions` and `/tree` pickers centered while scrolling, and removed wrap-around at list edges.
- Changed the saved session picker slash command to `/sessions`, with `/resume` kept as an alias.

### Fixed

- Fixed overlay open/close rendering so the interactive composer stays visible instead of briefly blinking away.
- Fixed interactive session diff totals to show the net workspace diff instead of counting repeated edits to the same lines multiple times.
- Fixed `/sessions` picker cancellation so Escape closes smoothly without a blink, while keeping the loading spinner visible as saved sessions are loaded.
- Fixed root-prompt session tree navigation so it no longer persists an empty active branch that makes cloned sessions resume with a blank transcript.
- Fixed `/resume` session picker entries to show cloned session ancestry as a tree.
- Made `/tree` branch indentation more visible in the terminal session picker.
- Fixed `Encoding::CompatibilityError` crash during compaction when tool results contained ASCII-8BIT (BINARY) strings from HTTP response bodies or shell output. Tool content is now normalized to UTF-8 on append.

## [0.69.1] - 2026-06-18

### Fixed

- Fixed `/tree` session rendering to tolerate malformed cyclic tree records instead of overflowing the Ruby stack.

## [0.69.0] - 2026-06-17

### Added

- Added a `docs:build` Rake task for building the YARD documentation site.
- Reworked core guide documentation around developer workflows, setup, authentication, memory, personas, extensibility, plugins, web search, and code search.
- Added `fetch_content` and `fetch_raw` web tools for reading specific URLs after search discovery.
- Added `enforce_workspace_agents_file` config support for forcing full workspace `AGENTS.md` injection.
- Added config-directory `PRINCIPLES.md` as the preferred global principles file, with `AGENTS.md` kept as a legacy alias.
- Added `kward sysprompt` for inspecting the effective system prompt, with `--raw` for unannotated prompt content.

### Changed

- Changed workspace `AGENTS.md` handling to inject a compact read-when-relevant instruction by default instead of the full file.
- Changed interactive runtime command/status messages to use a `Runtime>` transcript label instead of the assistant label.
- Changed terminal tool transcript rendering to show a single `Tool>` block containing the tool invocation summary and result summary.
- Changed transcript label colors to a quieter palette, with failed tool calls rendered in red.
- Separated conversation system prompt state from durable transcript messages; provider request context still includes the current system prompt on every model request.
- Persisted system prompt snapshots as session audit metadata when the prompt changes, without adding them to transcript messages.

### Fixed

- Fixed custom `ask_user_question` answers so trailing spaces remain visible while typing.
- Fixed inferred soft memory learning to canonicalize user preferences and avoid storing near-duplicate memories with slightly different wording.
- Fixed in-flight steering messages so they appear in the interactive transcript as `You>` entries.
- Fixed interactive plugin slash commands and OAuth login so they show the running spinner while executing.
- Fixed `/reload` so terminal plugin footers use the newly loaded plugin renderer without restarting Kward.
- Fixed Codex GPT-5.5 RPC model metadata to report a 400k context window instead of the upstream OpenAI API context window.
- Fixed a bug that prevented proper context window calculation whenever an image is attached to a session
- Fixed persona selection so workspace and model personas override the default base persona instead of appending duplicate base personas.
- Fixed Codex Responses streaming to preserve ordered response items, replay assistant phase metadata, and keep commentary/tool-planning text out of visible assistant output.
- Fixed Codex multi-turn requests with `store: false` by not replaying server-assigned response item ids.
- Fixed RPC session listing to include each session's persisted provider, model, and reasoning effort so pickers can show session-specific runtime state.

## [0.68.0] - 2026-06-14

In this release, most changes are under the hood, as it included massive refactors to have an even more robust way forward.

### Added

- Added Anthropic Claude Pro/Max subscription provider support with OAuth login, static Claude model choices, and Anthropic Messages streaming.

### Changed

- Changed known context windows and reasoning effort choices to use provider/model-specific metadata for Codex, OpenRouter, Copilot, and Anthropic models.
- Changed the default Anthropic model to Claude Sonnet 4.6 and expanded direct Anthropic model choices to include newer Claude Opus/Sonnet releases.
- Changed resumed sessions to restore the session's last-used provider, model, and reasoning effort without rewriting default config.
- Documented the tool contract: schemas define strict generated/returned payloads, while runtime accepts tolerant incoming tool-call input for compatibility.
- Expanded RDoc coverage past 50% across message compatibility, tool-call normalization, session persistence, session tree helpers, model/client boundaries, config paths, workspace operations, telemetry, RPC, plugins, memory, auth, compaction, search internals, CLI mixins, and prompt interface components.

### Fixed

- Fixed session tree editing and RPC fork text so prompt-template turns use the original visible slash command instead of expanded model content.

## [0.67.1] - 2026-06-14

### Fixed

- Fixed RPC session listing so it no longer deletes the active empty session file while UI clients are starting a first turn.

## [0.67.0] - 2026-06-13

### Added

- Added optional startup resume for the last active session in each workspace through `sessions.auto_resume: true`, including immediate restored transcript/persona data for RPC clients.
- Added `tools.workspace_guardrails: false` config support for allowing file tools to access paths outside the active workspace.
- Added `banner.enabled: false` config support for hiding the interactive terminal banner.
- Added colored CLI help/version commands, command-specific help, and stricter command precedence over one-shot prompts.
- Added `--working-directory PATH` as a global option for running any CLI mode from another workspace.
- Added `kward init` for installing the starter pack; `--install-starter-pack` remains as a compatibility alias.
- Added `kward doctor` to check local config, workspace, auth hints, Pan credentials, and writable directories.
- Added `--` as a prompt delimiter so option-like text can be sent as a one-shot prompt.
- Added `kward auth status` and `kward auth logout` for checking and clearing saved credentials without printing secrets.
- Added `/reload` and RPC runtime reload support for reloading installed plugins without restarting Kward.
- Added Session Tree support with a CLI `/tree` command plus RPC persisted entry IDs, labels, label timestamps, and branch navigation.
- Added RPC `ui/footer` notifications for Kward plugin footers.
- Added `!` shell commands in the interactive CLI composer.
- Added the active persona label to RPC `runtime/state` responses.

### Changed

- Expanded the interactive `/settings` command into categorized settings for model, accounts, memory, interface, tools, compaction, personalization, logging, and advanced config info.
- Changed RPC session deletion to use the OS trash/recycle bin when available before falling back to permanent file deletion.
- Changed automatic session naming to persist the first visible user turn, keeping slash prompt names unexpanded while still saving expanded prompt content.
- Changed Pan mode to start with the `kward pan` command; `--pan-mode` remains as a compatibility alias.
- Changed memory retrieval and listing to use a global core, workspace core, workspace soft hierarchy, and added `/memory relax` for downgrading global core memories to the current workspace.
- Changed session tree rendering to match Pi's active-path-first branch display, markers, tool rows, and connector prefixes.
- Changed session tree navigation so all persisted entry points are selectable without automatically running anything.

### Fixed

- Fixed RPC session deletion so empty unnamed sessions are explicitly deleted instead of being consumed by unused-session cleanup first.
- Fixed the TUI `/tree` selector to start on the current tree position, or the last item for a fresh tree.
- Fixed the normal session list/resume picker to stay in recent modification-time order, delete empty unnamed sessions, return the full list by default, and avoid test-created session pollution.
- Fixed RPC model selection to accept lowercase provider IDs from UI clients.
- Fixed cloned sessions to keep the current session name after renaming.

### Removed

- Removed the obsolete `/crew` command reservation and unreleased RPC compatibility aliases.

## [0.66.0] - 2026-06-12 - Codename: Order

### Added

- Initial public release.
- Prepare RubyGems packaging for the initial public release.
