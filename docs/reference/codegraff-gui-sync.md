# Codegraff GUI builds

Harness keeps its own source and release process. The
`codegraff-sync.yml` workflow checks Codegraff every 15 minutes. For
betas it selects the newest numeric `release/v*` branch and requires a
published beta tag at that branch's current head. For stable builds it
selects the highest numeric published stable tag. A
`codegraff_release_published` repository dispatch with `channel: beta`
or `channel: stable`, plus `tag` and `sha` (`branch` for beta), starts
the same check immediately. Dispatch values must agree with the live
release. The schedule also works when cross-repository dispatch is not
configured.

For either channel, the workflow downloads the exact
`graff-aarch64-macos.tar.gz` for that tag,
checks it against the release's `SHA256SUMS`, bundles it as
`Harness.app/Contents/Resources/bin/graff`, and uploads an app tarball as a
short-lived Actions artifact. It rechecks the branch before uploading so
an older beta cannot appear as current. It also rechecks the latest stable
tag before uploading a stable intermediate build. An Actions artifact is
for testing; it is not a signed macOS download or an updater release.

Stable desktop promotion still uses Harness's signed release process.
Distribution of a macOS app requires Developer ID signing, Apple
notarization, and a stapled ticket before the app or DMG is published.
