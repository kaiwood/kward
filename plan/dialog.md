# Release dialogue

## User

Looks good. Is it already time for a new release? Which photon torpedos are already loaded?

## Samantha

Yes, captain — **it’s probably time to cut a new release**, or at least enter release-prep mode.

Not “push the big red button immediately” time, but **release candidate time**.

Current state from the last pass:

- working tree clean
- full suite green: `1582 runs, 7175 assertions`
- docs check green
- release preflight task added
- changelog has meaningful unreleased material

Given the size of `[Unreleased]`, I’d make this a **minor release**, likely:

> `0.75.0`

Not a patch. There are enough added/changed behaviors.

## Photon torpedoes already loaded

### Major loaded torpedoes

- **Lifecycle hooks**
  - Runtime policy/automation hooks for tools, shell, files, turns, model events, etc.
  - Plugin hook support.
  - Allow/deny/ask/modify/warn decisions.

- **Agent Skills interoperability**
  - Discovery across Kward-native and `.agents/skills` locations.
  - `/skill` activation.
  - RPC skill commands.
  - Compaction preservation for activated skills.

- **RPC MCP/tool discovery metadata**
  - Session-aware tool listing.
  - MCP status.
  - Initialize capability reporting.

- **Release hygiene**
  - New `rake release:preflight`.
  - Builds docs, checks docs, runs tests, builds gem, prints packaged files.

### UX / behavior improvements

- RubyGems update notices on fresh interactive startup.
- Diff viewer mode setting: auto, unified, side-by-side.
- `/settings` picker flow improvements.
- Session command cleanup:
  - `/sessions` → `/session`
  - `/resume` kept as alias
  - `/name` replaced by `/session name`
- Session picker Tab search behavior improved.

### Fixes loaded

- RPC memory auto-summary now runs after completed RPC turns.
- Worker lifecycle hooks now actually block worker jobs before execution.
- RPC plugin reload now rebuilds existing session agent/tool/hook runtime.
- RPC plugin reload now has tool-hook regression coverage.
- Streamed Codex reasoning whitespace now collapses excessive blank lines.
- Default persona spelling fixed.
- Anthropic default model docs fixed.
- Context usage estimates fixed for restored sessions with different providers.
- Project skill discovery now uses active conversation workspace.

### Internal polish

- RPC transcript normalization now uses `MessageAccess`.
- Agent loop previously got `MessageAccess` cleanup too.
- Explicit guardrail added to avoid splitting large orchestration files just because they’re large.

## What I’d do before firing

The torpedoes are loaded, but I’d still run the release checklist:

```bash
bundle exec rake release:preflight
```

Then:

1. Inspect the packaged file list.
2. Install the built gem locally.
3. Smoke test `kward` in a clean workspace.
4. Move changelog `[Unreleased]` into `0.75.0`.
5. Bump `Kward::VERSION`.
6. Commit version bump.
7. Tag.
8. Push.
9. `gem push`.

So my recommendation:

> Yes — prepare `0.75.0`.

She’s armed, captain. I would not fire from inside spacedock, but I would absolutely bring us to tactical readiness.

## User

We don't do any release candidates, that is what OpenCode-Ferengis do! :O

## Samantha

Of course, captain. Forgive me.

Release candidates are for Ferengi procurement committees who need three signatures, two liability waivers, and a spreadsheet called `final_final_REAL.xlsx`.

We are Starfleet.

So the corrected answer is:

> Yes. It is time for a real release.

I’d cut **`0.75.0`**.

### Torpedoes loaded for `0.75.0`

- Lifecycle hooks and plugin hook runtime
- Agent Skills interoperability
- RPC MCP/tool discovery metadata
- RPC memory auto-summary parity
- Worker lifecycle hook blocking fixes
- RPC plugin reload fixes for existing sessions
- Streamed Codex reasoning whitespace cleanup
- Release preflight task
- Diff viewer setting
- Session command/search UX cleanup
- RubyGems update notices
- MessageAccess cleanup
- Docs/config/model fixes

### Fire sequence

```bash
bundle exec rake release:preflight
```

Then inspect the package list.

Then bump:

```ruby
# lib/kward/version.rb
VERSION = "0.75.0"
```

Move changelog `[Unreleased]` entries under:

```markdown
## [0.75.0] - 2026-07-09
```

Then:

```bash
git add CHANGELOG.md lib/kward/version.rb
git commit -m "Bump to 0.75.0"
git tag v0.75.0
git push
git push --tags
gem push kward-0.75.0.gem
```

Tiny note: because `release:preflight` builds the gem before the version bump if run too early, I’d run it **after** bumping the version/changelog, or run it once now for confidence and once after the bump for the actual artifact.

So, captain:

> Photon torpedoes are loaded. Recommend firing `0.75.0`.

## User

Just to be clear… We have a preflight Rake task?? When did this happen?

## Samantha

Yes, captain. We do now. 😇

It happened **five minutes ago in Step 4** of the “do all five, commit after each” sequence.

Commit:

```text
82395b7 Add release preflight task
```

It added this to `Rakefile`:

```ruby
namespace :release do
  desc "Run release checks and build a local gem"
  task preflight: [:test, "docs:check"] do
    gem_name = "kward-#{Kward::VERSION}.gem"
    FileUtils.rm_f(gem_name)
    sh "gem", "build", "kward.gemspec"
    puts packaged_gem_files(gem_name)
  end
end
```

And the helper:

```ruby
def packaged_gem_files(gem_name)
  gem = Gem::Package.new(gem_name)
  gem.spec.files.sort
end
```

So now this exists:

```bash
bundle exec rake release:preflight
```

It does:

1. runs the full test suite via `:test`
2. builds docs via `docs:check`
3. checks generated docs links/images/scripts
4. builds the gem
5. prints the packaged file list from the built gem

I also updated `doc/releasing.md` to use it as the primary release check.

So yes. We loaded a new torpedo tube while pretending it was routine maintenance.

## User

Ok, then do it this way. First: Save our conversation since "You> Looks good. Is it already time for a new release? Which photon torpedos are already loaded?" into plan/dialog.md (I'll tell you later why). Then: Do the git tag, git push, github release whatever, all the steps until I have to "gem push". Fire!
