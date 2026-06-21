# Releasing Kward

Release steps before publishing:

1. Update `CHANGELOG.md` for the version.
2. Update `Kward::VERSION` in `lib/kward/version.rb`.
3. Run the test suite:

   ```bash
   bundle exec rake test
   ```

4. Preview docs locally if you changed documentation or public APIs:

   ```bash
   bundle exec rake docs:serve
   ```

   YARD's built-in server reloads documentation on request while you edit. Open <http://localhost:8808/>.

5. Generate documentation:

   ```bash
   bundle exec rake rdoc
   bundle exec rake docs:build
   ```

   Pushes to `main` deploy the generated YARD site to GitHub Pages.

6. Build the gem locally:

   ```bash
   gem build kward.gemspec
   ```

7. Inspect the packaged files and confirm no local config, sessions, logs, or secrets are included.
8. Install the built gem locally and smoke test the `kward` executable.

Publish the built gem from the release checkout:

```bash
gem push kward-VERSION.gem
```

RubyGems MFA is required for publishing. Prefer RubyGems trusted publishing for automated releases if CI publishing is added later, so long-lived API keys do not need to be stored in CI secrets.
