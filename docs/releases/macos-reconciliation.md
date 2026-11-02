# Mac-only reconciliation release

This candidate targets macOS arm64. It is not cleared for publication by a
successful compilation, a preview test, or a merge alone. Windows, Linux, iPhone,
iPad and Android need a separate implementation/review and release decision.
Their current stable downloads and automatic-update feeds must remain unchanged.

## Build and publication paths

- Tag pushes and manual `release.yml` dispatches build only the signed/notarized
  macOS candidate, when the credentials are configured. They do not publish.
- Linux, Windows and companion release jobs are disabled in this candidate.
  TestFlight and Android release builds/uploads are disabled; App Store's
  read-only check remains available, but submission does not.
- `cut-release.yml` can tag an explicitly merged release PR and request the Mac
  candidate build. It cannot start TestFlight or publish artifacts.
- A tagged TUI dispatch cannot build or attach platform companions to this release.
- The local `stable_macos_release.py` path accepts only the two versioned Mac
  artifacts and the byte-identical DMG alias. Unexpected local or remote assets
  cause failure. `companions` is disabled.

After a clean tagged commit, prepare the distribution locally with
`scripts/package-macos.sh`, pinning the exact graff binary/version. Run
`stable_macos_release.py prepare --graff-version <version>` to verify Developer ID
signatures, notarization/stapling, executable identity across the bundle/DMG/app
archive, and SHA-256 hashes. This step is local only.

Test those exact distribution artifacts on Mac. Save the review JSON outside the
staging directory and outside tracked source, for example under `target/qa/`:

```json
{
  "platform": "macos-arm64",
  "version": "<release version>",
  "sourceCommit": "<full verified commit SHA>",
  "reviewer": "<human who checked the artifacts>",
  "artifactSha256": {
    "Harness-macos-arm64.dmg": "<SHA-256>",
    "harness-<release version>-macos-arm64.dmg": "<SHA-256>",
    "harness-<release version>-macos-arm64-app.tar.gz": "<SHA-256>"
  },
  "checks": {
    "launch": false,
    "workspace_restore": false,
    "session_close_recovery": false,
    "provider_switch": false,
    "browser_inspector": false,
    "image_gallery_annotation": false
  }
}
```

Only set a check true after testing that artifact. Evidence must match the
version, exact files and clean source commit; the local and remote tags must
identify that commit. Rebuilding or changing bytes invalidates the evidence.
Upload requires `--verification <path>` and leaves a draft. Publishing is a
separate, explicitly authorized action that rechecks local and remote digests.
No evidence for the final distribution has been created as part of the UI work.

## Automatic updates remain on their existing feeds

The Mac-only release is published at its versioned GitHub URL with
`--latest=false`. It does not modify GitHub's shared latest release, R2's shared
manifest/latest.txt, Windows aliases, or the updater's current endpoints. The
initial Mac-only release is therefore a versioned manual download. Do not
promote it through the shared feed: older Windows/Linux clients use that feed.
A future Mac-specific automatic-update channel needs a separate reviewed change.

No tag, draft upload, publication, release environment, credential, or live update
feed is changed merely by adding these guards. Nothing in this document
constitutes authorization to publish.
