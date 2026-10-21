# Releasing Lineado

Direct distribution: a notarized build on a GitHub Release, kept current by
Sparkle. The machinery is ported from Inbox & Chill, which has shipped this way
since its 1.0.

## Each release

1. **Bump both versions** in `project.yml` and commit:
   - `MARKETING_VERSION` — what people see, e.g. `0.1.0` → `0.2.0`.
   - `CURRENT_PROJECT_VERSION` — the build number. **It must go up every
     release.** Sparkle decides whether an update is newer by comparing this
     (`CFBundleVersion`), not the marketing version.
2. **Push**, so `main` matches `origin/main`. `release.sh` refuses to run from
   any other branch, on a dirty tree, or out of sync with GitHub.
3. **See the plan**, which changes nothing:

   ```bash
   scripts/release.sh --dry-run
   ```

4. **Release:**

   ```bash
   scripts/release.sh
   ```

It asks once before doing anything outward-facing, then:

- rebuilds Release from the current source — never reuses an old artifact;
- runs the preflight: Developer ID, secure timestamp, no `get-task-allow`,
  every one of Sparkle's nested helpers properly signed, and the bundle audit in
  `--release` mode (real feed URL, real public key);
- notarizes and staples, then produces `Lineado.zip` (what Sparkle downloads),
  `Lineado.dmg` (what a person downloads) and a dSYM (for crash reports);
- tags `vX.Y.Z`, creates the GitHub Release with those attached;
- regenerates `appcast.xml`, signing each entry, with each download link
  pointing at its own release's tag — then commits and pushes it.

Installed copies check the feed daily and offer the update. Sparkle always asks
before installing.

**A link for new users that never goes stale:**
`https://github.com/brandonlucasgreen/lineado/releases/latest/download/Lineado.dmg`

## One-time setup

### Notarization credentials

`notarize.sh` uses the keychain profile `inbox-and-chill`. The name is
historical: notarytool credentials belong to the Apple ID and team, not to an
app, so Lineado shares Inbox & Chill's. If it is missing:

```bash
xcrun notarytool store-credentials "inbox-and-chill" --apple-id <apple-id> --team-id CV926C8KS8
```

### The Sparkle signing key — already created, needs a backup

Created 2026-10-20 in the login keychain under the account **`lineado`**,
deliberately separate from Inbox & Chill's key. Its public half is baked into
`project.yml` as `SUPublicEDKey`.

**Back up the private half.** Every installed build trusts only that key. Lose
it and no existing install will ever accept another update — everyone would
have to download the app by hand again.

```bash
.sparkle/2.10.0/bin/generate_keys --account lineado -x lineado-sparkle-key.txt
```

Put that file in a password manager, then delete it. It must never reach this
repo.

**The first release will raise a Keychain dialog** asking whether `sign_update`
and `generate_appcast` may use the key. Choose **Always Allow**: they are the
two tools that should. Denying it aborts the appcast step with a message about
the request being cancelled.

## If something goes wrong

- **`notarize.sh --preflight-only`** builds Release and runs every check without
  credentials or submission. Run it first when a release fails before Apple.
- **The appcast step failed after the release was created.** The tag and Release
  exist; only the feed is behind. Fix the cause and run `scripts/appcast.sh`,
  then commit and push `appcast.xml`.
- **Sparkle's tools and framework must match.** Both are pinned to 2.10.0 —
  `exactVersion` in `project.yml`, `SPARKLE_VERSION` in
  `scripts/sparkle-tools.sh`. Bump them together.

## Known gaps

- **The feed lives at `raw.githubusercontent.com/.../main/appcast.xml`.** It can
  move to a custom domain later by shipping one update, through this feed, that
  names the new `SUFeedURL` — as long as this file keeps serving until
  installs have taken it.
