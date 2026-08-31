# Changelog

All notable changes to Kward will be documented in this file.

## [Unreleased]

### Added

- Added `/name` to rename the active session and tab together, including while the tab's agent is running.

### Fixed

- Fixed `/compact` completion output and cancellation so work remains owned by its originating tab instead of rendering into whichever tab is active.

## [0.84.0] - 2026-08-30

### Added

- Added security reporting, contribution and conduct policies, structured issue and pull-request templates, and an explicit macOS/Linux/WSL/Windows support matrix.
- Added Vibe multi-cursor editing with `Ctrl+D` occurrence selection from normal, insert, and characterwise visual modes, plus visual-mode `I`/`A` cursors at each selected line boundary.
- Added `script/benchmark_composer` for repeatable draft-layout, history-search, and file-completion performance measurements.
- Added Vibe visual and cursor-aware `:run` support plus `:run all` for executing runnable Markdown fenced language blocks and inserting or replacing their formatted `<output>` fields.
- Added configurable editor runners under `editor.runners`, with Node, TypeScript, Python, Shell, Lua, Julia, Elixir, Crystal, Go, and Swift buffer execution alongside Ruby.
- Added Vibe visual-mode `Ctrl+h`/`Ctrl+j`/`Ctrl+k`/`Ctrl+l` shortcuts to outdent, move down, move up, and indent selected lines while keeping visual mode active.
- Added a live `source`/`.` shell builtin that applies declarative aliases and exports to the running `/shell` session without restarting Kward.
- Added shell-agent provider, model, and reasoning-effort settings under `shell.agent`, editor-agent provider settings under `editor.agent`, and environment overrides for transient-agent provider selection.
- Added shell-style `kwshrc` configuration files at `~/.kward/kwshrc` and `~/.kwshrc`, with ordered `alias`, `export`, and declarative `source` support.
- Added the `open_editor` agent tool so interactive sessions, including explicit `/shell` `?` prompts, can open a requested workspace file in Kward's built-in editor.
- Extended `/scratchpad` to open all 26 built-in syntax-highlighted languages through canonical names or familiar file-extension shortcuts, with `/scratchpad help` for discovery.
- Added nested syntax highlighting, auto-indentation, and endwise behavior for recognized language tags inside fenced code blocks in Markdown editor buffers.

### Changed

- Smoothed interactive response streaming by pacing buffered provider events and rendering safe text before incomplete inline Markdown instead of delaying whole lines.
- Replaced the busy Braille spinner with a calmer four-frame activity pulse in the interactive composer.
- Added brief success, failure, and cancellation transitions to the interactive composer when an agent turn finishes.
- Standardized terminal accents by meaning: cyan for agent activity, green for success, amber for caution, red for failure, purple for tools, and gray for metadata.
- Added a brief, visual-only response-arrival flourish when the first assistant output reaches the interactive composer.
- Made the composer activity label follow real turn states such as thinking, reasoning, responding, retrying, and the currently running tool.
- Added unobtrusive elapsed-time feedback after two seconds, final turn duration in completion transitions, and provider-reported tool durations in result summaries.
- Added stable `❯` user and `✦` assistant anchors to make transcript turn boundaries easier to scan without changing stored conversation content.
- Added persistent background-tab status colors for running work, unread output, successful detached commands, questions, and failures without changing tab label widths.
- Restored green for ready tabs with unread output.
- Documentation checks now validate the curated public extension entry points without presenting aggregate internal-helper coverage as a product-quality metric.
- The repository and documentation landing pages now use a focused coding-workflow visual, restrained project badges, and clearer product identity.
- Updated RubyGems positioning and metadata to describe Kward's supported product surfaces and direct users to the documentation site while keeping source and issue links on GitHub.
- Refined the documentation homepage with a concrete static message, direct getting-started navigation, branded browser and social metadata, canonical URLs, and a quieter generated-docs footer.
- The composer now highlights `/` command and `@` file discovery, and the startup screen gives actionable guidance when no model provider is connected.
- Grouped and aligned top-level help, condensed credential status with an opt-in `--all` view, and standardized doctor, hooks, and project-skill diagnostics with actionable summaries and exit statuses.
- Pan now binds to `127.0.0.1` by default, accepts `KWARD_PAN_PASSWORD`, and warns whenever it is explicitly exposed over plain HTTP on a non-loopback address.
- Vibe visual selections can now be used as line ranges for `:` commands, including `:s` substitutions and `:run` scratchpad execution.
- Ruby scratchpad runs now preserve the source buffer and show captured output in a scrollable, cancellable lower-half output pane instead of appending it after `__END__`; mouse drag selection and `Ctrl+C`/`Cmd+C`/Vibe `y` copy clean output without pane borders.

### Fixed

- Restored Codex commentary as visible reasoning output during streaming and session replay instead of showing only the provider's short reasoning-summary headline.
- Kept expected Git discovery failures, PTY fixtures, and release subprocess output inside their owning tests so successful suite and CI logs remain quiet.
- Replaced one-shot authentication and runtime backtraces with concise, actionable CLI errors while retaining opt-in debug backtraces through `KWARD_DEBUG=1`.
- Fixed composer cursor movement, deletion, wrapping, truncation, and border alignment for wide and multi-codepoint Unicode graphemes.
- Reduced composer latency for long drafts, large file and slash-command lists, and prompt histories by eliminating repeated layout work, discovering project paths outside rendering, and reusing search results.
- Fixed tab switching during shell commands so tab shortcuts take priority without aborting the command; detached commands continue in the originating tab's background and report their output when complete.

### Removed

- Removed legacy `kwsh.yml` shell configuration; shell aliases and exports now use the shell-style `kwshrc` files.

## [0.83.0] - 2026-08-28

### Added

- Added `?` shell prompts for transient, context-aware assistance inside `/shell`, including shared shell-state commands and prepare-without-execute command drafts.
- Added `Ctrl+.` in Modern editor mode to open an in-editor prompt line for communicating with the dedicated editor agent.
- Added Vibe `:prompt <instruction>` support, allowing the agent to inspect and replace the active in-memory editor buffer without saving it automatically.
- Added current-buffer word completion to the integrated editor, with repeated Tab presses cycling nearby matches and existing smart indentation retained when no match exists.
- Added Claude Opus 5 to the Anthropic model picker with its 1M context window and high-reasoning metadata.
- Added an `i` toggle to the `/files` browser for showing Git-ignored files, which remain hidden by default.
- Added `f`, `d`, and `r` actions to the `/files` browser for creating files, creating directories, and renaming entries from the composer prompt.
- Added Backspace deletion to the `/files` browser with confirmation and an additional confirmation before recursively deleting non-empty directories.

### Changed

- `/shell` now keeps one persistent local shell process per tab so shell variables, functions, aliases, and directory changes are shared by user and agent commands.
- Shell-agent turns use a transient per-tab context and receive only bounded, sanitized output after an explicit `?` request; ordinary shell output remains outside model context.
- Shell-agent transcript output is now retained as bounded, tab-local runtime state so it survives tab switches without entering session history.
- Vibe editor-agent turns now use an isolated, configurable model/reasoning context, remain visible with a status-line spinner, and stay out of normal chat transcripts and session history.
- Removed the obsolete GPT-5.6 Luna Responses Lite compatibility workaround so Luna requests retain Kward's identity and standard Codex payload.

### Fixed

- Made persistent shell command cancellation and timeouts recover by restarting an unresponsive embedded shell, and stabilized raw-input coverage across platforms.
- Restored full-screen Git pagers and immediate key/Ctrl+C forwarding for interactive `/shell` commands by removing Kward's ambient `GIT_PAGER=cat` default and putting host input in raw mode during persistent-shell handoff, while keeping paging suppressed for captured and shell-agent commands.
- Fixed Claude subscription OAuth authorization and token-exchange requests by removing unsupported subscription scopes and the nonstandard `code` query parameter, and by forwarding the OAuth state to the token endpoint.
- Installed and enabled Bubblewrap during release verification so Linux worktree tests use the same sandbox setup as normal CI, added manual recovery for existing release tags, and made publication wait for and attach the canonical RubyGems artifact after trusted-publishing attestation.
- Fixed automatic context compaction so Codex response items are included in token estimates and long tool-call turns are checked before each model request.

## [0.82.0] - 2026-08-23

### Added

- Added `script/release` for validated, one-command release preparation from an argument or standard input, including changelog/version updates, preflight checks, an annotated tag, and an atomic push.
- Added a tag-triggered GitHub Actions release workflow using RubyGems trusted publishing, published-artifact checksum verification, changelog-based GitHub Releases, and safe reruns after partial publication.
- Added `+` and `-` controls for resizing inline `/files` image previews within the available overlay space.
- Added inline read-only previews for PNG, JPEG, GIF, and WebP files opened from `/files` in terminals that support Kitty or iTerm2 image sequences, with local conversion for Kitty-compatible terminals when needed.

### Changed

- Excluded GitHub workflow and local release-script files from packaged gems and added explicit release metadata and package-content checks.
- Changed interactive PTY handoff to render conservative line/progress output above a frozen composer, with a permanent switch to exclusive full-terminal passthrough when the child emits screen-oriented or unknown controls.
- Kept safe, normalized shell output as explicit tab-local transient state so completed `/shell` and `!command` output can be reconstructed after tab switches without entering session history or model context.

### Fixed

- Made the test environment explicitly disable terminal color and made unified diff-viewer tests select that mode explicitly, keeping release preflight assertions deterministic across terminal capabilities and widths.
- Kept `/files` image previews bounded within a fully cleared, bordered file-list overlay above the visible composer and preserved their aspect ratio in Kitty-compatible terminals.
- Fixed inline image protocol detection and viewer handoff for Ghostty and other Kitty-compatible terminals by retrying inconclusive probes, honoring recognized Kitty hints, suppressing Kitty acknowledgements, and using valid, chunked graphics sequences.
- Kept synchronized-output updates such as Homebrew downloads in the inline PTY region instead of resetting the cursor through an unnecessary exclusive handoff.
- Retained the final visible state of carriage-return and horizontal-cursor progress output from commands such as `git push` and Homebrew when reconstructing the transcript after PTY handback.
- Cached rebuildable session-list summaries so opening `/session` no longer reparses every unchanged conversation log, while retaining automatic fallback for existing, changed, or corrupt session data.
- Refreshed composer status immediately after model runtime changes and `/git` returns, so selected model details and Git dirty-state color do not remain stale until another input.
- Kept echoed passwords, OTPs, and other child input out of transient tab state by stopping safe PTY output retention before the first forwarded input byte.
- Reconstructed safe transient shell output as part of the PTY ownership handback frame, avoiding an extra clear and redraw after commands such as `ls`.
- Preserved the active `/shell` prompt and composer when Ctrl+L clears transient shell output, and avoided a redundant preliminary redraw.
- Reconstructed the complete Kward screen after interactive PTY handoff, including failure paths, instead of relying on the child process cursor position.

## [0.81.0] - 2026-08-20

### Added

- Added `capture <command>` inside `/shell` and `/capture <command>` in the normal composer for bounded, sanitized, transcript-friendly command execution.
- Added Tab completion for shell commands and paths when the normal interactive prompt input begins with `!`.
- Added workspace-scoped, digest-aware project skill trust decisions with interactive Allow, Deny, and Review prompts plus `/skills` and `kward skills` management commands.

### Changed

- Displayed packaged plugins with their folder name in the startup plugin list, such as `folder/plugin.rb`.
- Added a frozen composer display for line-oriented Git PTY commands while preserving the full-terminal handoff for full-screen programs.
- Changed external `/shell` commands and one-shot `!command` input to use interactive PTY terminal handoff by default, while retaining `pty` and `/pty` for compatibility.
- Made aliases configured in `kwshrc` available to leading-`!` execution and command completion.
- Removed interactive PTY start and exit-status messages while retaining the submitted command echo.
- Changed shell and leading-`!` completion so the candidate list appears in an interactive overlay while repeated Tab presses cycle through candidates in the composer.
- Removed the `Tab` and `Shift+Tab` reasoning-effort shortcuts so the composer keeps its normal completion behavior.

### Fixed

- Refreshed composer status immediately after reasoning selection and interactive PTY commands, so reasoning levels and Git branch state no longer remain stale until the next input.
- Prevented composer flicker during interactive prompt, bang-command, and slash-command submission by deferring the submitted composer's repaint to the next command state.
- Preserved the busy composer while writing normal-turn transcript output so user-submission rendering does not clear it.
- Bound CSI-u `Ctrl+Q` input to close the read-only `/git diff` viewer, matching the existing raw-key binding and ESC behavior.
- Routed leading-`!` commands and aliases resolving to `kward edit <filename>` into the integrated editor instead of spawning a nested Kward process.
- Preserved safe, line-oriented PTY output such as `ls` by redrawing it into the transient transcript when returning from `/shell`, `!command`, or `/pty`, while leaving full-screen and keyboard-driven sessions terminal-owned.
- Removed legacy `pty` and `capture` mode markers from configured aliases expanded by `!command`, preventing valid aliases such as `glog: pty git log` from failing with status 127.
- Hardened interactive PTY cleanup, final-output draining, input EOF handling, resize propagation, and stopped-child recovery so terminal handoff reliably returns control to Kward.
- Normalized binary-tagged UTF-8 shell output before transcript rendering, preventing interactive `!` commands such as `tree` from crashing the composer.
- Deferred interactive warning output until startup transcript replay completes, keeping Runtime diagnostics visible instead of immediately overwriting them with the replayed transcript.

## [0.80.1] - 2026-07-27

### Fixed

- Avoided repeated full-buffer syntax scans while rendering generic-language editor lines, keeping Python and other supported languages responsive during cursor movement.
- Routed interactive configuration, plugin, skill, compaction, memory, and logging warnings through synchronized `Runtime>` output so diagnostics cannot corrupt the terminal layout.

## [0.80.0] - 2026-07-27

### Added

- Added HTML/Ruby syntax highlighting and common-block auto-indentation for `.erb` files in the integrated editor.
- Added catalog-based API-key login and model selection for OpenAI, Anthropic, Azure OpenAI, Gemini, Cerebras, DeepSeek, Fireworks AI, Groq, Mistral, NVIDIA NIM, OpenRouter, Together AI, and xAI, with private credential storage and live/cached/curated model catalogs.
- Added native streaming runtimes for the OpenAI Responses API, Google Gemini, and Azure OpenAI, including tool calls, usage metadata, retries, cancellation, and secret redaction.
- Added RPC parity for provider/auth-method discovery, sanitized credential status, API-key login/logout, model refresh, and provider/model selection.
- Added a dedicated model-provider guide with the canonical provider list, runtime IDs, authentication, model configuration, discovery behavior, and limitations.
- Added a prompt-template guide, including template creation, slash-command expansion, and the starter templates installed by `kward init`.
- Added a Stardate footer plugin example for the interactive CLI.
- Added a general transport plugin API with normalized messages and events, persistent transport state, policy checks, managed lifecycle, foreground CLI commands, and RPC capability/status reporting.
- Added a first-party Telegram long-polling transport example with fixed-workspace routing, numeric allowlists, idempotent updates, message chunking, and interactive approval/question buttons.
- Added packaged plugin entrypoints under `~/.kward/plugins/*/plugin.rb` for multi-file trusted plugins.
- Added generic transport execution profiles and an isolated Telegram chat transport with no tools, plugin commands, memory, attachments, or interactions.
- Added a shared scoped plugin-chat runtime and `Transport::Host#plugin_chats` for explicitly transport-capable plugin chats, including actor context, event replay, cancellation, and separate transport/RPC access.
- Added transport-only plugin chats with `local: false`, keeping externally targeted plugin chats out of local tab opening and restoration.
- Added Git worktree bindings for normal interactive session tabs. `/tab worktree` can move a tab into a strict linked-worktree workspace after research, preserve its transcript, warn about dirty origin changes, and keep the branch available when explicitly detached.
- Added the active worktree `git_commit` model tool, allowing explicitly requested agent commits through the trusted host-side Git workflow without widening the shell sandbox.
- Added `/tab worktree merge` for explicitly merging a clean worktree branch into the branch checked out in its original workspace, plus `/tab worktree merge abort` for conflicted merges.
- Added `/worktree` as a concise alias for `/tab worktree` on the active tab.
- Added `j`/`k` keyboard navigation to the `/files` project browser.
- Added `h`/`l` keyboard navigation for collapsing and expanding `/files` directories.
- Added `j`/`k` keyboard navigation to the `/git` changed-file overlay.

### Changed

- Avoided copying bounded transcript buffers into idle tab snapshots while preserving intentional full-conversation scrollback replay when those tabs are revisited.
- Kept the TUI transcript buffer under its existing limit while trimming to a safe low watermark instead of copying the full buffer after every appended character.
- Reduced integrated-editor layout work by caching line starts and calculating the cursor line once per rendered frame.
- Limited interactive plugin footer evaluation to its authoritative one-second refresh interval and reused the cached value between refreshes.
- Made interactive plugin canvases publish only complete frames submitted with `ui.render`, skip unpublished ticks, and follow terminal width changes.
- Avoided rebuilding and flushing the TUI composer when tab labels and selection have not changed.
- Reduced interactive streaming overhead by writing each labeled TUI delta in one synchronized prompt transaction.
- Highlighted the current editor line number in white while keeping the rest of the line-number gutter green.
- Made `/model` provider-aware with refresh, manual model IDs, capability-filtered defaults, Show all, and provider switching while preserving Codex, Copilot, OpenRouter, and local models.
- Kept direct OpenAI API credentials (`openai_api`) separate from ChatGPT/Codex OAuth so both can be configured at once.
- Azure OpenAI setup now validates HTTPS endpoints, deployment names, and API versions, and treats the configured deployment as the selectable model.
- Updated current documentation to describe Copilot and the JSON-RPC backend as supported features rather than experimental ones.
- Clarified the distinct roles of workspace guardrails, tool permissions, and command sandboxing.
- Reorganized the README documentation index and clarified generated Ruby API support boundaries.
- Added task-oriented navigation to the RPC and configuration references.
- Standardized MCP support and limitation wording across the user and RPC guides.
- Reframed the README introduction around Kward as an Agentic Development Environment (ADE) with opt-in safety controls.
- Moved the local-model setup guide to the generated documentation Integrate navigation.
- Added the Telegram transport deployment guide to the generated documentation navigation.
- Replaced implicit `/tab worktree` detachment with explicit `/tab worktree detach`; running `/tab worktree` again now leaves an active worktree enabled.
- Added workspace overrides for foreground transports via `kward transport run NAME WORKSPACE` and the global `--working-directory` option.
- The `/files` project-browser now uses full terminal height if there are enough files to fill that space

### Fixed

- Prevented a stopped tab live-view thread from resuming against a newly active tab after a slow render.
- Kept `@`/`$` completion, `/files`, prompt history, and the integrated editor rooted in the active worktree tab instead of the original checkout.
- Fixed HTML and ERB editor highlighting so tag names, attributes, values, and tag fragments retain consistent colors across embedded Ruby expressions.
- Refreshed composer diff and context usage status immediately when switching session tabs.
- Prevented `/reload` from retaining stale prompt templates, so new and edited prompt files refresh slash-command completion and expansion.
- Prevented session-picker rename input from filtering the visible session list.
- Fixed session listing timestamps and ordering to ignore system-prompt and other metadata writes during session restoration.

## [0.79.0] - 2026-07-19

### Added

- Added a Local OpenAI-compatible model provider for Ollama, LM Studio, and llama.cpp, including model discovery, streamed tool calls, configurable context windows, CLI/RPC model selection, and a local-model setup guide.
- Added replacement system-prompt files and an option to omit global principles for smaller-model prompt budgets.
- Added skill capture from saved session branches. Review model-generated personal `SKILL.md` drafts in the CLI or Pan, or use the equivalent RPC workflow before explicitly saving them.
- Added opt-in OS-enforced sandboxing for model-requested shell commands. macOS uses Seatbelt and Linux uses Bubblewrap when available; requested sandboxing fails closed when no supported backend can enforce it. The interactive `/sandbox` command reports and updates the global policy.

### Changed

- Clarified command-sandbox configuration, platform setup, and limits across the security, permissions, workspace-tools, RPC, and configuration guides.
- Sandboxed command workers now receive a sanitized environment with a private home and temporary directory; the macOS backend also blocks reads from common credential directories.
- Improved built-in tool guidance so agents use only tools advertised for the current turn and select code search, compacted-output retrieval, and structured clarification when appropriate.
- Raised the minimum supported Ruby version from 3.2 to 3.4.

### Fixed

- Reject duplicate discovered tool names instead of silently replacing one MCP tool with another.
- Fixed an RPC race where follow-up input could queue instead of steering a turn immediately after it began.
- Prevented the RPC server from loading trusted Ruby plugins separately for plugin chats and workspace sessions, eliminating duplicate constant-definition warnings during startup.
- Prevented `/reload` and RPC runtime reloads from emitting duplicate constant-definition warnings for plugin-defined constants.
- Wrapped long side-by-side diff cells when editor soft wrap is enabled instead of clipping their contents.

## [0.78.0] - 2026-07-15

### Added

- Added opt-in transcript-observer delivery for plugin-owned tabs, including RPC plugin chats, so local integrations such as text-to-speech can receive permitted streamed replies.
- Added opt-in RPC support for plugin-owned chats, including explicit subscriptions, transcript snapshots, attachment-capable turns, event replay, and cancellation. Plugins remain disabled from this surface unless their tab type explicitly opts in.
- Added plugin-owned tab types, opened with `/tab open <plugin-tab>`, with typed tab persistence and the normal interactive composer, transcript, streaming, and image-input behavior. Plugin tabs are CLI-only in this release and own their own storage rather than Kward sessions.
- Added an opt-in permission policy for model-requested tools, with allow/ask/deny rules, read-only and workspace-write modes, write scopes, and interactive approval overlays. Permissions remain disabled by default and are not an OS sandbox.
- Added a custom-response path to permission approval overlays: choosing `Type something` denies the requested tool call and returns the entered guidance to the agent.

### Changed

- Plugin-chat transcript RPC supports optional bounded, cursor-based pages for plugin drivers that opt in, avoiding full-history payloads for long-lived chats.
- Code search now synchronizes mutable repository refs before every read and search, reports the resolved commit, and accepts GitHub blob URLs as file inputs.
- Web and code research tools now cooperate with turn cancellation between requests, provider attempts, redirects, and repository scan files.
- Kward-owned HTTP requests now identify themselves with `User-Agent: Kward/<version>`.

### Fixed

- Fixed `fetch_content` site navigation by preferring semantic main content over nested article cards, preserving inline and standalone link destinations, listing bounded discovered navigation links, and extracting ordered lists and simple tables.
- Prevented duplicate session-backed tabs from restoring as mirrored conversations after restart.
- Fixed `fetch_content` on documentation pages with large scripts or metadata before the main content by separating bounded page downloads from extracted output limits; plain-text extraction now parses HTML instead of returning cleaned markup.
- Fixed raw fetches so their response limit is enforced while reading the network body.
- Fixed stale code-search reads and searches by treating cached repositories as reusable local storage rather than authoritative snapshots.
- Restored GPT-5.6 Luna requests through Codex with a scoped Responses Lite compatibility workaround; normal Codex requests retain Kward's own identity.

## [0.77.0] - 2026-07-11

### Added

- Added `firstChangedLine` to successful RPC file-mutation results when Kward can derive it from the unified diff, allowing clients to navigate to the first changed line.
- Added an opt-in Nerd Font icon theme for the `/files` browser, configurable through Interface settings or `project_browser.icons`; text-only rows remain the default.
- Added Vim-style Vibe editor reindent commands: `==`, `={motion}` and text objects, plus visual `=`; reindentation uses the built-in language-aware auto-indent rules.
- Added a security and trust guide covering local permissions, external data flow, trusted extensions, stored data, and safe use with unfamiliar repositories.
- Added a dedicated Pan mode guide covering setup, browser and session workflows, prompt queueing, extensions, network security, and limitations.
- Added an interactive composer guide covering editing keys, command and file completion, history, reasoning and tab shortcuts, busy input, cancellation, images, and terminal compatibility.
- Added session browsing, creation, resume, rename, and deletion to Pan mode, with a responsive mobile-first interface using the documentation palette, Kward logo, and CLI-inspired startup screen.
- Added dependency-free Markdown rendering for Pan transcript entries, including fenced code blocks, lists, blockquotes, inline styles, and safe links.

### Fixed

- Restored busy-tab `/tab` commands, including tab naming, switching, opening, and moving, without replacing the running tab's agent.
- Fixed `/reload` so newly loaded plugin slash commands appear in the interactive completion overlay.
- Pan mode now uses the active persona label for assistant messages and interface copy instead of a fixed Kward label.
- Pan mode now prints the routed LAN address in its startup URL when available.
- Fixed RPC session close, delete, and shutdown operations to cancel active turns before releasing session state, with a bounded fallback for uncooperative workers.
- Fixed concurrent RPC turn event recording so replay sequence numbers remain unique and ordered.
- Kept intentional empty-session garbage collection from deleting live CLI or RPC session files.
- Removed scheduler timing from the throttled CLI streaming test and restored Ruby 4 image-attachment compatibility.

### Removed

- Removed the experimental worker pipeline, tab-backed worker queue, related CLI flag and commands, RPC capability, lifecycle hooks, and stored-runtime integration. Existing session files, worker metadata, and Git stashes are left untouched.

### Changed

- Improved documentation navigation, command and settings coverage, editor and diff-view workflows, configuration task guidance, and generated API comments for supported extension surfaces.
- CI now tests the minimum supported Ruby and the current stable Ruby.
- Removed unused private CLI, transcript-rendering, layout, and shell helpers, and clarified compaction guard naming.
- Removed production Ruby warnings and added a warning-free runtime require check to CI.
- Limited session listings now fully reconstruct only the requested newest sessions while still garbage-collecting abandoned empty files.

## [0.76.0] - 2026-07-10

### Added

- Added GPT-5.6 Sol, Terra, and Luna to the OpenAI/Codex model choices and made GPT-5.6 Sol the default OpenAI/Codex model.
- Added Claude Sonnet 5 and Fable 5 to the Anthropic model choices and made Claude Sonnet 5 the default Anthropic model.

### Fixed

- Fixed Codex reasoning summaries so separate summary messages render as separate blocks with one empty line between transcript blocks.
- Fixed interactive update notices so stale checks refresh before the startup banner and new configs expose the `updates.check` setting.

## [0.75.0] - 2026-07-09

### Added

- Added `rake release:preflight` to run release checks, build docs, build the gem, and print packaged files.
- Added cached RubyGems update notices on the fresh interactive startup screen.
- Added an Interface `/settings` option for choosing the integrated diff viewer mode: auto, unified, or side-by-side.
- Added lifecycle hooks for deterministic runtime policy and automation, including Ruby plugin hooks, command hooks configured in `config.json`, tool/shell/file/turn/model events, and allow/deny/ask/modify/warn decisions.
- Added Agent Skills interoperability across `~/.agents/skills`, project `.agents/skills`, Kward-native skill directories, explicit `/skill` activation, RPC skill commands, resource listing, and compaction preservation for activated skills.
- Added RPC MCP/tool discovery metadata, session-aware `tools/list`, `mcp/status`, and initialize capability reporting for MCP discovery.

### Changed

- Changed code search to share the web/fetch HTTP adapter for package and GitHub lookups.
- Changed OpenAI and Anthropic OAuth flows to share browser callback and token helper mechanics.
- Changed context token counting to reuse loaded tokenizer encodings per model.
- Changed RPC capability format names from Tauren-specific identifiers to Kward-neutral identifiers.
- Changed `/settings` to require only picker support, with live overlay redraw remaining optional for overlay-specific settings.
- Changed new default configs to include explicit overlay and web-search defaults while preserving existing behavior for partial configs.
- Changed interactive `/settings` menus to return to the last changed option instead of resetting to the first settings screen.
- Changed the saved session picker slash command from `/sessions` to `/session`, kept `/resume` as an alias, and replaced `/name` with `/session name`.
- Changed session picker search to use Tab, and Tab again returns to the list without clearing the current search text.

### Fixed

- Fixed RPC memory auto-summary so completed RPC turns learn memories when memory and auto-summary are enabled.
- Fixed worker lifecycle hooks so create/start blocking decisions stop worker jobs before they run.
- Fixed RPC plugin reloads so existing sessions rebuild their agent, tool registry, and lifecycle hook runtime.
- Fixed streamed Codex reasoning whitespace so repeated blank lines collapse to a single empty line.
- Fixed default persona spelling in new configs and the documented Anthropic default model.
- Fixed context-usage estimates for restored sessions whose provider differs from the current client default.
- Fixed project skill discovery to use the active conversation workspace instead of the process working directory.

## [0.74.0] - 2026-06-30

### Added

- Added more Vim-compatible Vibe editor bindings, including `Y`, `>>`/`<<`, `~`, `g_`, `|`, `W`/`E`/`B`, `ge`/`gE`, case operators, `gJ`, counted `%`, previous-change mark jumps, jump-list navigation, and linewise paste semantics.
- Added local stdio MCP server support through `mcpServers`, exposing configured MCP server tools to Kward turns.
- Added smartcase, live cursor movement, cancel restore, and visible match highlighting to editor search.
- Added Vibe editor `:e <filename>` and `:e! <filename>` commands with path tab completion.
- Added `--skip-config` as an emergency fallback that ignores the main config file for one run.

### Fixed

- Fixed tab switching while busy local commands such as `/compact` are running, including restoring the busy spinner when returning to the tab.
- Fixed repeated compaction for compacted sessions that continue growing after later turns.
- Fixed editor undo/redo so selections do not become sticky after restoring buffer contents.
- Fixed busy composer slash commands so they are blocked instead of being queued or sent as in-flight steering.

## [0.73.1] - 2026-06-30

### Fixed

- Fixed Vibe editor `dG` so it deletes from the current line through the end of the file.
- Fixed session picker delete confirmation in terminals that send printable keys as CSI-u escape sequences.

## [0.73.0] - 2026-06-29

### Added

- Added persistent session-backed worker queue job metadata as the first step toward tab-based worker queues.
- Added experimental `/queue add` and `/queue list` commands for enqueueing the current tab session into the worker queue.
- Added a first session-backed worker queue runner that executes one queued job and marks it ready for review after committing changes.
- Added clean-workspace blocking for queued workers so jobs do not start on top of existing local changes.
- Added `/queue run` to manually drain queued tab worker jobs sequentially until the queue is empty or a job needs attention.
- Added worker git stash helpers as groundwork for cooperative queue suspension.
- Added explicit queue runner suspend/resume primitives that stash and restore a running job's workspace changes.
- Added `/queue suspend <id>` and `/queue resume <id>` commands for manually parking and resuming queued worker jobs.
- Added `/queue open <id>` to open a queued worker's session for review or follow-up.
- Added `/diff` to open the chronological file changes recorded in the current session in the integrated diff viewer.
- Added `/scratchpad [text|markdown|ruby]` for opening unsaved editor buffers, including Vibe `:w filename` save-as support and Ruby `:run`/Modern `Ctrl+R` output written after `__END__`.
- Added `/pty <command>` and the `kwsh` `pty <command>` built-in for explicit interactive PTY passthrough sessions, enabling terminal-owned tools such as pagers to run from Kward.
- Added minimal PTY execution for external `kwsh` commands so terminal-aware tools can detect a TTY and terminal width.
- Added Ctrl+C cancellation for running `kwsh` commands and preserved tab-switch actions while shell commands are active.
- Added quoted path completion and cached `$PATH` executable completion for `kwsh`.
- Added streaming `kwsh` command output in the TUI transcript while commands run.
- Added separate workspace-scoped `kwsh` command history so embedded shell input no longer shares normal prompt history.
- Added structured RPC `runtime/updateSetting` `defaultModel` values so clients can send provider and model separately while keeping the existing string format.

### Changed

- Changed PTY-backed `kwsh` commands to refresh terminal window size while running so long-lived commands can adapt to resizes.
- Changed `kwsh` to default `GIT_PAGER` to `cat`, while preserving user-provided values, so Git commands do not unexpectedly enter an interactive pager under PTY execution.
- Improved `kwsh` POSIX-oriented built-ins, including `exit [status]`, stricter `cd`/`pwd`, `export NAME`, assignment persistence, `unalias`, and shared alias-name validation.
- Changed `kwsh` configuration to prefer a POSIX `/bin/sh` default shell and validate runtime settings for command timeout, output cap, and shell history size.

### Fixed

- Normalized ordinary PTY line endings in `kwsh` command output so transcripts avoid stray carriage returns.
- Added `kwsh` timeout and output-limit enforcement for external commands using the shared local command runner.
- Consolidated workspace shell command execution on a shared local command runner with timeout, cancellation, bounded capture, and optional streaming support.
- Fixed `kwsh` shell output sanitization so unsafe terminal controls are stripped before command output is shown while SGR color is preserved.
- Split Vibe editor insert/readline key handling into a focused mixin without changing editor behavior.
- Consolidated compaction message-field reads through the shared message access helper.
- Consolidated RPC transcript tool metadata normalization with tool event metadata so tool names, args, diffs, and changed files stay aligned.
- Fixed RPC tool capabilities so `changedFiles` is advertised when emitted in tool results.
- Removed a stale `count-tests` CLI branch that could crash instead of treating the input as a prompt.
- Fixed tab failures and cancellations so red tab states always emit a runtime message explaining what happened.
- Fixed model and reasoning changes from CLI/RPC settings so active session runtime metadata is persisted before the next turn.
- Fixed `context_for_task` so candidate files with no task matches return a clear no-match message instead of only a header.
- Fixed workspace file tools so expected filesystem permission and path-type errors are returned as tool errors instead of aborting a turn.
- Fixed composer `Ctrl+C` so it no longer exits the app when no process is running.
- Fixed the Git diff viewer so `Ctrl+C` and terminal-forwarded `Cmd+C` copy selected text.
- Fixed pasted or dropped shell-escaped image paths so the composer hides the path text after adding the image badge.
- Fixed `read_skill` tool transcript rendering so skill frontmatter starts on the line after the tool label.
- Fixed built-in editor soft-wrap vertical movement so moving up or down preserves the visual column across wrapped visual rows and logical line boundaries.

## [0.72.0] - 2026-06-28

### Added

- Added a built-in editor that can be opened from the TUI with `$` or directly from the CLI with `kward edit <filename>`, with modern, Emacs-style, and Vibe editing modes.
- Added richer editor workflows including syntax highlighting, undo/redo, auto-indent, soft wrap, mouse support, multi-cursor editing, relative line numbers, and an expanded Vim-like Vibe mode with visual selections, text objects, registers, marks, macros, substitution, and Ruby navigation.
- Added `/shell`, an embedded Kward shell (`kwsh`) for running workspace commands without leaving the TUI, including command/path completion, safe color output, optional global `kwshrc` configuration, and rbenv shim autodetection.
- Added `/files`, a searchable project file browser that can open files in the editor and remembers cursor and folder expansion state per workspace.
- Added persistent TUI tabs for session-backed conversations, plus tab commands, shortcuts, status colors, and restoration across restarts.
- Added `/git` workflows for reviewing changes, viewing diffs, staging or unstaging files, and writing commit messages from inside the TUI.
- Added TUI composer improvements including `@` file mentions, persistent workspace prompt history with Ctrl+R search, and Tab/Shift+Tab reasoning-effort cycling.
- Added CLI execution modes via `--mode auto|chat|oneshot|filter` and `--filter` for transforming piped input.
- Added context-budgeting tools and workflows, including `read_file` modes, richer source outlines, `context_for_task`, `context_budget_stats`, and restored compacted tool-output inspection.
- Added interactive plugin commands backed by a Kward-driven canvas render loop.
- Added experimental agent-worker support behind the existing experimental workflow.
- Added new and expanded guides for editor usage, tabs, project files, Git workflows, agent tools, context budgeting, workspace tools, web search, code search, plugins, RPC, authentication, memory, sessions, troubleshooting, and releasing.

### Changed

- Changed the built-in editor to use the modern editing mode by default, with smarter indentation and improved keyboard handling across terminal encodings.
- Improved TUI interaction polish across pickers, tabs, editor rendering, Git workflows, composer refresh behavior, mouse handling, and modal input isolation.
- Improved embedded shell environment handling so Kward-managed environment values are preserved while workspace shell conveniences still work.
- Improved RPC and session internals around steering events, session cleanup, worker metadata, session-tree traversal, and config updates.
- Improved tool-output context budgeting so agents start with focused context, preserve inspectable originals, and report active-conversation savings more accurately.
- Expanded documentation and generated-doc navigation to better reflect current workflows and configuration options.

### Fixed

- Fixed embedded-shell completion, environment preservation, and rbenv handling issues.
- Fixed editor and TUI input edge cases involving shifted keys, CSI-u encodings, Command/Ctrl shortcuts, selection preservation, mouse scrolling, tab switching, modal questions, and commit-message editing.
- Fixed many built-in editor behaviors around selection rendering, cursor movement, soft wrap, indentation, deletion/change operations, undo/search behavior, macro recording, registers, text objects, visual mode, and viewport positioning.
- Fixed Git overlay staging and commit-message behavior.
- Fixed session, tab, and worker state issues including tab restoration, session cleanup, worker handoff, foreground write locks, and plugin/test isolation.
- Fixed RPC steering, tool-output restoration, context-budget statistics, and session-manager lifecycle behavior.
- Fixed documentation rendering, navigation, tables, quote styling, and generated guide layout issues.
- Fixed persona time-of-day handling to use the current local time.

### Removed

- Removed the placeholder message from `/status` output.
- Removed unused RPC session helpers and temporarily hid worker labels behind the experimental worker flow.

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
