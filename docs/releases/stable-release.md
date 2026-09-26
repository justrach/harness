# Stable release

How a stable Harness release ships. The macOS app is built, Developer ID
signed and notarized on the signing Mac; the tag workflow builds the Linux and
Windows companions. `scripts/stable_macos_release.py` verifies all of it,
stages the assets and publishes. Run it with an arm64 Python 3.12 or newer
(Homebrew's `/opt/homebrew/bin/python3.13`): `xcrun` can't load under Rosetta.

1. On `main`, bump `version` in `Cargo.toml` (`cargo metadata` refreshes
   `Cargo.lock`), add `docs/releases/v<version>.md`, commit, and push. Then
   tag and push the tag; the release workflow builds the companions.

   ```sh
   git tag -a v<version> -m "Harness v<version>" && git push origin v<version>
   ```

2. Build, sign and notarize the macOS app against a pinned graff release:

   ```sh
   export CODESIGN_IDENTITY='Developer ID Application: <your signing identity>'
   export NOTARYTOOL_PROFILE=codedb-notary
   export GRAFF_RELEASES_URL='https://github.com/justrach/codegraff/releases/download/v<graff>'
   scripts/package-macos.sh
   ```

3. When the tag workflow has finished, download the companions, verify
   everything and upload it to a draft release. The draft is created from the
   release notes if it doesn't exist yet; the release stays a draft.

   ```sh
   python3 scripts/stable_macos_release.py release --graff-version <graff>
   ```

   `prepare` checks the app, the updater tarball and the DMG for Developer ID
   signatures, hardened runtime, secure timestamps, staple tickets, the app
   version and bundle ID, and the exact bundled graff version, and that all
   three carry the same executables. It stages the stable aliases
   (`Harness-macos-arm64.dmg`, `Harness-windows-x86_64.zip`) and a
   `manifest.json` with every asset's SHA-256. `upload` checks GitHub's stored
   digests against that manifest. A failed check is a stop condition.

4. Look over the draft on GitHub, then publish it:

   ```sh
   python3 scripts/stable_macos_release.py publish
   ```

   `publish` rechecks the digests, marks the release latest, and reads the
   public `releases/latest/download/manifest.json` back.

The macOS app and the Windows updater read the latest GitHub release. The
managed `curl | sh` installer reads the `harness-releases` bucket, which only
the tag workflow's publish job writes when signing secrets are configured.
