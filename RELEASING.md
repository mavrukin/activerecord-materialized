# Releasing

This gem is published to [RubyGems](https://rubygems.org) through **trusted
publishing**: a GitHub Actions workflow ([`.github/workflows/release.yml`](.github/workflows/release.yml))
exchanges a short-lived OIDC token for a RubyGems API key at publish time, so
no long-lived secret is ever stored in this repository.

You only do the **one-time setup** once. After that, every release is a tag push.

---

## One-time setup

1. **Create a RubyGems account** at https://rubygems.org/sign_up and **enable
   MFA** (Settings → Multi-factor authentication). The gemspec sets
   `rubygems_mfa_required`, so MFA is required to own and push this gem.

2. **Register a pending trusted publisher.** Because the gem does not exist on
   RubyGems yet, register it as *pending* — the first successful publish creates
   the gem and makes you its owner. Go to
   https://rubygems.org/profile/oidc/pending_trusted_publishers/new and enter:

   | Field | Value |
   |-------|-------|
   | RubyGems gem name | `activerecord-materialized` |
   | Repository owner | `mavrukin` |
   | Repository name | `activerecord-materialized` |
   | Workflow filename | `release.yml` |
   | Environment | `release` |

   (After the first release, manage this under the gem's **Trusted Publishers**
   tab instead.)

3. **Create the `release` environment** in GitHub (Settings → Environments →
   *New environment* → `release`). This is optional but recommended — you can
   add a required-reviewer protection rule so a human approves each publish. The
   environment name must match both the workflow and the trusted-publisher
   config above.

---

## Cutting a release

1. Make sure `main` is green and contains everything for the release.

2. Set the version in [`lib/activerecord/materialized/version.rb`](lib/activerecord/materialized/version.rb)
   following [SemVer](https://semver.org). (For the very first release the value
   is already `0.1.0`, so you can skip the bump and go straight to tagging.)

3. Update [`CHANGELOG.md`](CHANGELOG.md): give the release a dated heading.

4. Open a PR with the version + changelog changes, get CI green, and merge.

5. Tag the merge commit on `main` and push the tag:

   ```bash
   git checkout main && git pull
   git tag v0.1.0      # must equal the VERSION constant
   git push origin v0.1.0
   ```

6. The **Release** workflow runs automatically. It verifies the tag matches the
   `VERSION` constant, builds the gem, publishes it to RubyGems via trusted
   publishing, and creates a GitHub Release with the `.gem` attached.

7. Verify:

   ```bash
   gem install activerecord-materialized
   ```

   and confirm the page at https://rubygems.org/gems/activerecord-materialized.

---

## Manual fallback

If you ever need to publish without the workflow (for example, to claim the gem
name before configuring trusted publishing):

```bash
gem build activerecord-materialized.gemspec
gem push activerecord-materialized-0.1.0.gem   # prompts for credentials + OTP
```

Inspect exactly what a release will contain at any time with:

```bash
gem build activerecord-materialized.gemspec
tar -xOf activerecord-materialized-*.gem data.tar.gz | tar tzf -
```

The `spec/gemspec_spec.rb` guard test enforces that only `lib/` code and the
top-level docs are packaged.
