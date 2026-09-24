#!/usr/bin/env python3
"""Offline checks for the stable desktop manifest contract."""

import tempfile
import unittest
from pathlib import Path

from stable_macos_release import (
    expected_names,
    has_exact_graff_version,
    make_manifest,
    sha256,
)


class StableMacosReleaseTests(unittest.TestCase):
    def test_manifest_hashes_all_release_assets_and_alias_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            for name in expected_names("0.2.85"):
                (dist / name).write_bytes(b"signed dmg" if name.endswith(".dmg") else name.encode())
            manifest = make_manifest("0.2.85", dist)
            self.assertEqual(manifest["version"], "0.2.85")
            self.assertEqual(set(manifest["files"]), set(expected_names("0.2.85")))
            self.assertEqual(
                manifest["files"]["Harness-macos-arm64.dmg"]["sha256"],
                sha256(dist / "harness-0.2.85-macos-arm64.dmg"),
            )
            (dist / "Harness-macos-arm64.dmg").write_bytes(b"different")
            with self.assertRaisesRegex(ValueError, "alias differs"):
                make_manifest("0.2.85", dist)

    def test_exact_graff_release_excludes_dirty_and_dev_builds(self):
        self.assertTrue(has_exact_graff_version("graff v0.0.302.5\n", "0.0.302.5"))
        self.assertFalse(
            has_exact_graff_version("graff v0.0.302.5-1-gabc-dirty\n", "0.0.302.5")
        )
        self.assertFalse(has_exact_graff_version("graff v0.0.302.4\n", "0.0.302.5"))


if __name__ == "__main__":
    unittest.main()
