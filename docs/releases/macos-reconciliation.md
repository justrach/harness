# Mac-only reconciliation release

This candidate targets macOS arm64. It is not cleared for publication by a
successful compilation, a preview test, or a merge alone. Windows, Linux, iPhone,
iPad and Android need a separate implementation/review and release decision.
Their current stable downloads and automatic-update feeds must remain unchanged.

## Build and publication paths

The integration preserves the upstream release workflows and the existing
`scripts/stable_macos_release.py` multi-platform release path. Merging the
workspace changes does not publish a release. The disabled jobs used in the
isolated Mac review candidate are not part of the integration.

A Mac-only distribution remains a separate, explicitly authorized release:

- Do not push a release tag or dispatch the shared release workflows for this
  candidate: those workflows retain their normal multi-platform behavior.
- Do not use a `release/v*` branch for the integration pull request; merging that
  release branch can run the upstream release automation.
- The release owner still needs to choose the Mac version and the tag/publication
  route. No independent Mac-only publication route is ready.
- The dedicated `scripts/macos_candidate_release.py` helper accepts only the two
  versioned Mac artifacts and the byte-identical DMG alias. Unexpected local or
  remote assets cause failure. `companions` is disabled in this helper only.
  No workflow calls it automatically.

The candidate helper still requires a local and remote `v<version>` tag before
upload or publication. Pushing that tag can start the unchanged shared release
workflow, including other platforms and shared feeds. `--latest=false` in the
local helper does not prevent a separately triggered workflow from publishing.
Do not use its `upload`, `publish` or `release` commands until the release owner
has resolved this routing and authorized the release. This document does not
choose a new tag namespace or change the existing release policy.

For local preparation, build from a clean commit with
`scripts/package-macos.sh`, pinning the exact graff binary/version. Run
`python3 scripts/macos_candidate_release.py prepare --graff-version <version>`
to verify Developer ID signatures, notarization/stapling, executable identity
across the bundle/DMG/app archive, and SHA-256 hashes. This step is local only and
stages under `target/macos-candidate-release/`, separate from the existing stable
release staging directory.

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
Once the release route has been resolved, upload requires
`--verification <path>` and leaves a draft. Publishing is a separate, explicitly
authorized action that rechecks local and remote digests.
No evidence for the final distribution has been created as part of the UI work.

## Automatic updates remain on their existing feeds

The candidate helper's publication command uses a versioned GitHub URL and
`--latest=false`. That command does not modify GitHub's shared latest release,
R2's shared manifest/latest.txt, Windows aliases, or the updater's current
endpoints. These safeguards apply to the helper itself; they do not solve the
shared-workflow tag trigger described above. A versioned manual Mac download
remains the intended outcome, pending the release owner's routing decision.
Do not promote it through the shared feed: older Windows/Linux clients use that
feed. A future Mac-specific automatic-update channel needs a separate reviewed
change.

No tag, draft upload, publication, release environment, credential, or live update
feed is changed merely by merging the workspace changes. Nothing in this document
constitutes authorization to publish.
