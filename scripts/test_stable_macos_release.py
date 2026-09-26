#!/usr/bin/env python3
"""Offline checks for the stable desktop manifest contract."""

import tempfile
import unittest
from pathlib import Path

from stable_macos_release import (
    ALIASES,
    companion_names,
    expected_names,
    has_exact_graff_version,
    make_manifest,
    sha256,
)


class StableMacosReleaseTests(unittest.TestCase):
    def stage(self, dist: Path, version: str) -> None:
        for name in expected_names(version):
            (dist / name).write_bytes(name.encode())
        for alias, target in ALIASES.items():
            (dist / alias).write_bytes((dist / target.format(version=version)).read_bytes())

    def test_manifest_hashes_all_release_assets_and_aliases_match(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            self.stage(dist, "0.2.92")
            manifest = make_manifest("0.2.92", dist)
            self.assertEqual(manifest["version"], "0.2.92")
            self.assertEqual(set(manifest["files"]), set(expected_names("0.2.92")))
            self.assertEqual(
                manifest["files"]["Harness-macos-arm64.dmg"]["sha256"],
                sha256(dist / "harness-0.2.92-macos-arm64.dmg"),
            )
            for alias in ALIASES:
                (dist / alias).write_bytes(b"different")
                with self.assertRaisesRegex(ValueError, "alias"):
                    make_manifest("0.2.92", dist)
                self.stage(dist, "0.2.92")

    def test_every_platform_the_updaters_download_is_a_release_asset(self):
        names = set(expected_names("1.2.3"))
        # crates/update: macOS app tarball, Linux tarballs, Windows exe.
        for name in [
            "harness-1.2.3-macos-arm64-app.tar.gz",
            "harness-1.2.3-linux-x86_64.tar.gz",
            "harness-1.2.3-linux-aarch64.tar.gz",
            "harness-1.2.3-windows-x86_64.exe",
        ]:
            self.assertIn(name, names)
        self.assertTrue(all(n.startswith("harness-1.2.3-") for n in companion_names("1.2.3")))

    def test_exact_graff_release_excludes_dirty_and_dev_builds(self):
        self.assertTrue(has_exact_graff_version("graff v0.0.302.5\n", "0.0.302.5"))
        self.assertFalse(
            has_exact_graff_version("graff v0.0.302.5-1-gabc-dirty\n", "0.0.302.5")
        )
        self.assertFalse(has_exact_graff_version("graff v0.0.302.4\n", "0.0.302.5"))


if __name__ == "__main__":
    unittest.main()
