# Releasing Kward

Kward requires Ruby >= 3.2 (`spec.required_ruby_version` in `kward.gemspec`). If you develop with a newer Ruby, verify tests pass against the minimum supported version before releasing.

Release steps before publishing:

1. Update `CHANGELOG.md` for the version. Move `[Unreleased]` entries under a new version heading.
2. Update `Kward::VERSION` in `lib/kward/version.rb`.
3. Run the release preflight:

   ```bash
   bundle exec rake release:preflight
   ```

   This runs the full test suite, builds and checks the generated docs, builds a local gem, and prints the packaged file list for review.

4. Run focused tests for any areas you changed during the release prep itself (docs, config, etc.):

   ```bash
   ruby -Itest test/test_cli.rb
   ```

5. Preview docs locally if you changed documentation or public APIs:

   ```bash
   bundle exec rake docs:serve
   ```

   The preview builds `_yardoc/`, serves it with WEBrick, and rebuilds in a fresh process when documentation sources, library code, or templates change. Refresh your browser after rebuilds.

6. If you want to run the documentation check separately:

   ```bash
   bundle exec rake docs:build
   bundle exec rake docs:check
   ```

   `docs:check` validates generated internal links, images, and scripts. Pushes to `main` deploy the generated YARD site to GitHub Pages. You can also run `bundle exec rake rdoc` to generate a separate RDoc site as a sanity check, but it is not deployed.

7. Inspect the packaged files printed by `release:preflight` and confirm no local config, sessions, logs, or secrets are included. The gemspec uses `git ls-files` and excludes `test/`, `plan/`, `.ruby-lsp/`, `.gitignore`, and `AGENTS.md`.

8. Install the built gem locally and smoke test the `kward` executable in a clean workspace.

Commit the version bump and create a git tag:

```bash
git commit -am "Bump to VERSION"
git tag vVERSION
git push && git push --tags
```

Publish the built gem from the release checkout:

```bash
gem push kward-VERSION.gem
```

RubyGems MFA is required for publishing. Prefer RubyGems trusted publishing for automated releases if CI publishing is added later, so long-lived API keys do not need to be stored in CI secrets.

If a published gem has a serious problem, you can yank it within 24 hours of pushing:

```bash
gem yank kward --version VERSION
```

Yanking removes the gem from the default install index but does not delete the version entirely. After yanking, fix the issue, bump the version, and release again.
