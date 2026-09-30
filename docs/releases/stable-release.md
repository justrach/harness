# Stable release

With the macOS signing secrets set on the repository (`MACOS_CERT_P12`,
`MACOS_CERT_PASSWORD`, `AC_API_KEY_P8`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`),
pushing the tag is the whole release: the workflow builds, signs, notarizes
and staples the macOS app, then publishes every asset, both stable aliases and
`manifest.json` under the notes in `docs/releases/v<version>.md`. It also fills
the `curl | sh` installer's bucket when `CODEGRAFF_CLOUDFLARE_API_TOKEN` is
set. The steps below are the path from a signing Mac, for when CI can't sign.

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

## Beta releases

A beta is a GitHub prerelease for testing a change before it ships to everyone.
Use it to try something on real machines first; promote it by cutting the next
stable release.

- **Version and tag.** The next stable is `0.2.100`; its betas are
  `0.2.100-beta.1`, `0.2.100-beta.2`, and so on. `-beta.<n>` is the only
  prerelease suffix the workflow accepts; anything else fails the tag build.
- **What a beta touches.** Only a GitHub prerelease, marked not-latest. It never
  writes the stable aliases (`Harness-macos-arm64.dmg`,
  `Harness-windows-x86_64.zip`), `manifest.json`, `latest.txt` or the
  `curl | sh` bucket, so stable installs and the auto-updater cannot see it.
- **What the build does differently.** A beta build has features that are
  still being staged switched on; a stable build keeps them off until they are
  promoted. `HARNESS_CHATGPT_PLAN=0` or `=1` overrides that for the ChatGPT
  plan sign-in.
- **Updating.** A beta install updates itself to the next stable release: a
  release outranks its own betas (`0.2.100` > `0.2.100-beta.2` > `0.2.99`).
  Moving between betas is manual: install the newer prerelease.

To cut one, on the branch you want to test:

1. Set `version` in `Cargo.toml` to `0.2.100-beta.1` (`cargo metadata`
   refreshes `Cargo.lock`) and add `docs/releases/v0.2.100-beta.1.md`.
2. Commit, push, then tag and push the tag. The tag workflow builds, signs and
   notarizes everything and publishes the prerelease.

   ```sh
   git tag -a v0.2.100-beta.1 -m "Harness v0.2.100-beta.1" && git push origin v0.2.100-beta.1
   ```

Do not use `scripts/stable_macos_release.py` for a beta: it marks the release
latest and stages the stable aliases. Betas ship through the tag workflow only.

To promote, merge the change, then cut `0.2.100` as a stable release above.
