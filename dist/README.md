# Packaging

## Linux (implemented)

```sh
scripts/package-linux.sh            # release build (thin LTO, stripped)
PROFILE=debug scripts/package-linux.sh   # fast smoke package
```

Produces `target/package/zeron-<version>-linux-<arch>.tar.gz` containing:

- `zeron` — the binary (headed by default; `zeron headless` runs the engine alone)
- `zeron.desktop` — XDG desktop entry
- `zeron.png` — 1024×1024 Zeron app icon
- `install.sh` — installs into `~/.local/{bin,share/applications,share/icons}`

The release profile in the root `Cargo.toml` sets `lto = "thin"` and
`strip = "symbols"` for distribution builds.

## macOS

```sh
GRAFF_BINARY=/path/to/graff scripts/package-macos.sh
```

The script builds `Harness.app`, bundles the supplied Graff CLI, and produces
`target/package/harness-<version>-macos-<arch>.dmg` plus an app tarball for
stable updates. Omit `GRAFF_BINARY` to fetch the latest stable Graff release
and verify it against that release's `SHA256SUMS`. `HARNESS_BINARY` can point
to an already tested Harness executable. Signed distribution builds set
`CODESIGN_IDENTITY` and either App Store Connect notary credentials or
`NOTARYTOOL_PROFILE`; the script signs nested code, notarizes the app and DMG,
and staples both. `Harness.app` seeds its bundled Graff into the user's
Harness managed directory and puts the CLI on the terminal PATH on first open.

The DMG artwork is generated from the synthetic plate with
`swift scripts/dmg-background.swift`. The rendered 1x and 2x backgrounds are
committed so packaging does not require a graphics generator.
