# Releasing Flight

Flight ships as a Developer ID signed, notarized macOS app with Sparkle updates
served from GitHub Releases.

## One-time setup

### Branch protection (the security boundary)

Every push to `main` cuts a release, so the gate against an attacker shipping a
signed, notarized build is whoever can push to `main`. Configure a branch
ruleset before adding the Apple/Sparkle secrets below:

1. Repo settings → Rules → Rulesets → New branch ruleset.
2. Target the `main` branch.
3. Require pull requests, require at least one approving review, and
   restrict who can push directly (admins only, ideally none).

Tag protection isn't useful here — the workflow itself creates `v*` tags via
`gh release create`, so a tag rule would either block CI or need a CI bypass
that defeats its purpose. Branch protection on `main` is the real boundary.

### Release environment

The `Release` workflow runs inside a GitHub Actions environment named
`release`. Create that environment in repo settings → Environments — no
reviewers needed; the environment exists so the secrets below are scoped to
this one workflow rather than being readable by every workflow in the repo.

### Apple and Sparkle credentials

Create a Developer ID Application certificate in the Apple Developer account,
export it as a password-protected `.p12`, then add these GitHub Actions secrets
to the `release` environment:

| Secret | Purpose |
|---|---|
| `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` export for the Developer ID Application certificate. |
| `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `APPLE_ID` | Apple ID used by `notarytool`. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for the Apple ID. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `SPARKLE_PRIVATE_ED_KEY` | Private EdDSA key from Sparkle's `generate_keys` tool. |

Add these repository variables:

| Variable | Purpose |
|---|---|
| `SPARKLE_PUBLIC_ED_KEY` | Public EdDSA key from Sparkle's `generate_keys` tool. |
| `FLIGHT_BUNDLE_ID` | Optional bundle identifier override. Defaults to `com.flight.app`. |
| `SPARKLE_FEED_URL` | Optional appcast URL override. Defaults to the latest GitHub Release `appcast.xml` asset. |

To generate the Sparkle key pair locally:

```bash
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

The public key goes into `SPARKLE_PUBLIC_ED_KEY`; the private key goes into
`SPARKLE_PRIVATE_ED_KEY`. Keep the private key secret. Existing installations
will only accept updates signed by the matching private key.

## Release flow

Releases are continuous: every push to `main` runs the `Release` workflow.
There is no separate cutting step. To ship, merge to `main`.

Versions follow CalVer in the form `YYYY.MM.MICRO` (e.g. `2026.04.0`,
`2026.04.1`, …). The workflow computes the next tag itself by scanning for
existing `v<year>.<month>.*` tags and bumping the trailing counter, so two
releases in the same month auto-increment without anyone picking a number.
The trailing counter resets to `0` on the first release of a new month.

For each push the workflow will:

1. Compute the next CalVer tag.
2. Build `Flight.app`.
3. Embed Sparkle and enable automatic update checks.
4. Sign with the imported Developer ID certificate.
5. Submit the zip to Apple notarization.
6. Staple the notarization ticket.
7. Generate a signed `appcast.xml`.
8. Create the GitHub Release (which also creates the `v…` tag) and upload
   `Flight-<version>.zip` and `appcast.xml` as assets.

Sparkle uses `CFBundleVersion` (set to the GitHub Actions run number, which is
strictly monotonic per repo) to decide which build is newer, so the CalVer
display string is purely cosmetic for ordering purposes — there's no risk of
two releases tying.

### Hotfixes and re-runs

There is no manual trigger. To recover from a transient failure (notarization
flake, Apple service blip), open the failed run in the Actions tab and click
"Re-run jobs" — the workflow will recompute the next CalVer tag and ship the
build at `main`'s current `HEAD`. To ship a code fix, merge it to `main` like
any other change.

### Skipping a release

Every push to `main` releases. If you need to ship a docs-only change without
a new build, edit `.github/workflows/release.yml` to add a `paths-ignore`
filter (e.g. `**.md`, `doc/**`).

## Local builds

Local builds do not require Apple credentials:

```bash
./build.sh
open Flight.app
```

Sparkle is disabled unless both `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`
are set at build time.
