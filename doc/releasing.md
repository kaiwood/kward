# Releasing Kward

Kward releases are prepared locally and published by GitHub Actions. The local command updates the version and changelog, runs every release check, creates the release commit and annotated tag, then pushes both atomically. The tag-triggered workflow publishes the gem to RubyGems.org and creates a GitHub Release with the same gem attached.

## One-time setup

Kward publishes through [RubyGems trusted publishing](https://guides.rubygems.org/trusted-publishing/), so the repository does not need a long-lived RubyGems API key.

Before the first automated release:

1. In the GitHub repository, create an Actions environment named `release`. Add required reviewers if releases should have a manual approval gate.
2. On the RubyGems.org page for the `kward` gem, add a trusted publisher with:
   - Repository owner: `kaiwood`
   - Repository name: `kward`
   - Workflow filename: `release.yml`
   - Environment: `release`
3. Confirm GitHub Actions can write repository contents. The release job requests only `contents: write` for the GitHub Release and `id-token: write` for RubyGems OIDC authentication.

GitHub Packages is intentionally not used. RubyGems.org remains the canonical package registry; the built `.gem` is also attached to each GitHub Release.

## Prepare a release

Keep notable changes under the appropriate `Added`, `Changed`, `Fixed`, or `Removed` heading in the `[Unreleased]` section of `CHANGELOG.md`. Do not add the version heading by hand.

Before releasing, make sure `main` is clean, pushed, and synchronized with `origin/main`. Then run:

```bash
script/release 0.82.0
```

The version can also come from standard input:

```bash
printf '0.82.0\n' | script/release
```

The command fails closed unless:

- The version is a valid RubyGems version newer than `Kward::VERSION`.
- The working tree is clean and checked out on `main`.
- Local `main` exactly matches `origin/main`.
- The tag does not exist locally or on GitHub.
- RubyGems.org does not already contain the version.
- `[Unreleased]` contains at least one changelog entry.

If validation succeeds, it:

1. Updates `Kward::VERSION` in `lib/kward/version.rb`.
2. Refreshes `Gemfile.lock` with `bundle lock --local`.
3. Moves the unreleased changelog entries under a dated version heading.
4. Runs `bundle exec rake release:preflight`.
5. Commits the three release files as `Release v0.82.0`.
6. Creates an annotated `v0.82.0` tag.
7. Atomically pushes `main` and the tag to `origin`.

If preparation fails before the commit, the command restores the version, lockfile, and changelog. If tagging or pushing fails after the commit, it leaves the release commit in place and prints the failed command; inspect the repository before retrying rather than creating another release commit.

## What the release workflow does

A pushed `v*` tag starts `.github/workflows/release.yml`. The workflow:

1. Checks that the tag, gem version, and changelog heading agree.
2. Installs and enables Bubblewrap, then runs the full test suite and generated-documentation checks against Ruby 3.4 using the same Linux sandbox setup as normal CI.
3. Builds the gem and verifies its packaged files.
4. Publishes through RubyGems trusted publishing.
5. Downloads the canonical published gem from RubyGems.org, waiting for propagation when necessary, and verifies its checksum against the RubyGems API.
6. Creates `Kward VERSION` as a GitHub Release using that version's changelog section and attaches the verified RubyGems artifact.

The publishing job uses the protected `release` environment. If RubyGems.org already has the version after a partially completed workflow, a rerun downloads and verifies the canonical published gem before continuing. This also accommodates trusted-publishing attestations that can change the published gem bytes. For an existing GitHub Release, the workflow downloads and compares the gem, uploads it when missing, and publishes an unfinished draft. This makes normal workflow reruns safe without silently replacing mismatched artifacts.

If the workflow itself needs a fix after a tag has already been pushed, commit and push the fix to `main`, then recover the existing tag with the updated workflow:

```bash
gh workflow run Release --ref main -f tag=v0.82.0
```

Manual recovery still checks out and verifies the tagged source before publishing. The `release` environment permits automatic version-tag runs and manual recovery runs from `main` only.

Follow the run from the repository's **Actions → Release** page. Installation can be checked after publication with:

```bash
gem install kward --version 0.82.0
kward --version
```

## Run checks without releasing

After updating to an unreleased version, run the complete preflight directly with:

```bash
bundle exec rake release:preflight
```

This verifies release metadata, runs tests, builds and checks the generated documentation, builds `pkg/kward-VERSION.gem`, rejects development-only packaged files, and prints the final gem contents.

Individual checks remain available:

```bash
bundle exec rake test
bundle exec rake docs:check
bundle exec rake release:verify
bundle exec rake build
```

Use `bundle exec rake docs:serve` to preview documentation locally.

## If you need to yank a release

If a published gem has a serious problem, yank it within 24 hours of pushing:

```bash
gem yank kward --version VERSION
```

Yanking removes the gem from the default install index but does not delete the version. Fix the issue, choose a new version, and run the normal release command again. Never move or reuse a published version tag.
