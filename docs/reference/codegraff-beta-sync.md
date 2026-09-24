# Codegraff beta builds

Harness keeps its own source and release process. The
`codegraff-beta.yml` workflow checks the newest numeric Codegraff
`release/v*` branch every 15 minutes. A `codegraff_release_published`
repository dispatch with `channel: beta`, `branch`, `sha`, and `tag` can
start the same check immediately. The dispatch values must agree with the
published beta tag and current branch head; the schedule also works when
cross-repository dispatch is not configured.

The workflow downloads the exact `graff-aarch64-macos.tar.gz` for that tag,
checks it against the release's `SHA256SUMS`, bundles it as
`Harness.app/Contents/Resources/bin/graff`, and uploads an app tarball as a
short-lived Actions artifact. It rechecks the branch before uploading so
an older build cannot appear as the current beta. An Actions artifact is
for testing; it is not a signed macOS download or an updater release.

Stable desktop updates still use Harness's signed release process.
Distribution of a macOS app requires Developer ID signing, Apple
notarization, and a stapled ticket before the app or DMG is published.
