# Releasing Kward

Release steps that can be completed before publishing:

1. Update `CHANGELOG.md` for the version.
2. Update `Kward::VERSION` in `lib/kward/version.rb`.
3. Run the test suite:

   ```bash
   bundle exec rake test
   ```

4. Generate documentation:

   ```bash
   bundle exec rake rdoc
   bundle exec yard doc
   ```

5. Build the gem locally:

   ```bash
   gem build kward.gemspec
   ```

6. Inspect the packaged files and confirm no local config, sessions, logs, or secrets are included.
7. Install the built gem locally and smoke test the `kward` executable.

RubyGems setup before the first public release:

1. Create or sign in to a RubyGems.org account.
2. Enable multi-factor authentication for the account.
3. Confirm the `kward` gem name is available.
4. Add final homepage, source code, changelog, documentation, and bug tracker metadata to `kward.gemspec` once the public repository URLs are final.
5. Prefer RubyGems trusted publishing for automated releases so long-lived API keys do not need to be stored in CI secrets.
6. Push the built gem or publish through the trusted publishing workflow.
