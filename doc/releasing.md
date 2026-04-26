# Releasing Flight

Flight ships as a Developer ID signed, notarized macOS app with Sparkle updates
served from GitHub Releases.

## One-time setup

The `Release` workflow runs inside a GitHub Actions environment named
`release`. Create that environment in repo settings → Environments and add
yourself (or another Mirage maintainer) as a required reviewer. Scope the
secrets below to the `release` environment so they are only readable by jobs
that have been manually approved.

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

Create and push a version tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The `Release` workflow will:

1. Build `Flight.app`.
2. Embed Sparkle and enable automatic update checks.
3. Sign with the imported Developer ID certificate.
4. Submit the zip to Apple notarization.
5. Staple the notarization ticket.
6. Generate a signed `appcast.xml`.
7. Publish `Flight-<version>.zip` and `appcast.xml` to the GitHub Release.

You can also run the workflow manually with a version. For urgent releases, set
`critical_update` to mark the Sparkle appcast item as critical. That is the
strongest update pressure available through Sparkle; true silent forced
deployment still requires MDM.

## Local builds

Local builds do not require Apple credentials:

```bash
./build.sh
open Flight.app
```

Sparkle is disabled unless both `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`
are set at build time.
