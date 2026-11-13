#!/usr/bin/env python3
"""Offline checks for the Mac-only candidate artifact and evidence contract."""

import io
import json
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import unittest
from pathlib import Path

from macos_candidate_release import (
    ALIASES,
    companion_names,
    expected_names,
    has_exact_graff_version,
    make_manifest,
    validate_verification,
    validate_draft_scope,
    require_verified_candidate,
    check_remote_digests,
    publish,
    companions,
    REQUIRED_CHECKS,
    sha256,
)


class MacosCandidateReleaseTests(unittest.TestCase):
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

    def test_only_macos_artifacts_are_permitted(self):
        self.assertEqual(set(expected_names("1.2.3")), {
            "Harness-macos-arm64.dmg", "harness-1.2.3-macos-arm64.dmg",
            "harness-1.2.3-macos-arm64-app.tar.gz",
        })
        self.assertEqual(companion_names("1.2.3"), ())
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            self.stage(dist, "1.2.3")
            (dist / "harness-1.2.3-windows-x86_64.zip").write_bytes(b"unverified")
            with self.assertRaisesRegex(ValueError, "unexpected artifacts"):
                make_manifest("1.2.3", dist)
        with patch("macos_candidate_release.run") as run:
            with self.assertRaisesRegex(ValueError, "disabled"):
                companions(SimpleNamespace(version="1.2.3"))
            run.assert_not_called()

    def evidence(self, manifest):
        return {
            "platform": "macos-arm64", "version": manifest["version"],
            "sourceCommit": "a" * 40, "reviewer": "Fixture reviewer",
            "artifactSha256": {name: item["sha256"] for name, item in manifest["files"].items()},
            "checks": {check: True for check in REQUIRED_CHECKS},
        }

    def test_verification_cannot_be_reused_for_different_source_bytes_or_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            self.stage(dist, "1.2.3")
            manifest = make_manifest("1.2.3", dist)
            valid = self.evidence(manifest)
            validate_verification(valid, manifest, "a" * 40)
            for field, value in [
                ("platform", "windows-x86_64"), ("version", "1.2.2"),
                ("sourceCommit", "b" * 40), ("reviewer", ""),
                ("artifactSha256", {}), ("checks", {c: "true" for c in REQUIRED_CHECKS}),
            ]:
                with self.subTest(field=field), self.assertRaises(ValueError):
                    validate_verification({**valid, field: value}, manifest, "a" * 40)
            for check in REQUIRED_CHECKS:
                invalid = {**valid, "checks": {**valid["checks"], check: False}}
                with self.subTest(check=check), self.assertRaises(ValueError):
                    validate_verification(invalid, manifest, "a" * 40)

    def test_missing_evidence_fails_before_network_or_publication(self):
        with patch("macos_candidate_release.run") as run:
            with self.assertRaisesRegex(ValueError, "verification"):
                require_verified_candidate(SimpleNamespace(verification=None), {})
            run.assert_not_called()

    def test_verification_requires_clean_source_and_matching_local_and_remote_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            self.stage(dist, "1.2.3")
            manifest = make_manifest("1.2.3", dist)
            evidence_path = dist / "qa.json"
            evidence_path.write_text(json.dumps(self.evidence(manifest)))
            args = SimpleNamespace(version="1.2.3", verification=evidence_path)
            sha = "a" * 40
            cases = [
                ([" M source.rs\n"], "clean source"),
                (["", "b" * 40], "source commit mismatch"),
                (["", sha, "b" * 40], "release tag"),
                (["", sha, sha, "b" * 40], "remote release tag"),
            ]
            for results, error in cases:
                with self.subTest(error=error), patch("macos_candidate_release.run", side_effect=results) as run:
                    with self.assertRaisesRegex(ValueError, error):
                        require_verified_candidate(args, manifest)
                    self.assertEqual(run.call_count, len(results))
            with patch("macos_candidate_release.run", side_effect=["", sha, sha, sha]) as run:
                require_verified_candidate(args, manifest)
                self.assertEqual(run.call_args.args[0:2], ("gh", "api"))

    def test_remote_release_cannot_contain_unverified_platform_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            self.stage(dist, "1.2.3")
            manifest = make_manifest("1.2.3", dist)
            assets = [{"name": name, "digest": "sha256:" + entry["sha256"]}
                      for name, entry in manifest["files"].items()]
            assets += [{"name": "manifest.json", "digest": "sha256:wrong"}]
            with patch("macos_candidate_release.run", return_value=json.dumps({"assets": assets})):
                with self.assertRaisesRegex(ValueError, "manifest"):
                    check_remote_digests("1.2.3", manifest)
            assets += [{"name": "Harness-windows-x86_64.zip", "digest": "sha256:unchecked"}]
            with patch("macos_candidate_release.run", return_value=json.dumps({"assets": assets})):
                with self.assertRaisesRegex(ValueError, "unexpected"):
                    check_remote_digests("1.2.3", manifest)

    def test_existing_draft_with_another_platform_is_rejected_before_upload(self):
        valid = {"tagName": "v1.2.3", "isDraft": True, "isPrerelease": False, "assets": []}
        validate_draft_scope(valid, "1.2.3")
        with self.assertRaisesRegex(ValueError, "outside"):
            validate_draft_scope({**valid, "assets": [{"name": "Harness-windows-x86_64.zip"}]}, "1.2.3")
        with self.assertRaisesRegex(ValueError, "unpublished"):
            validate_draft_scope({**valid, "isDraft": False}, "1.2.3")

    def test_publishing_does_not_advance_latest_or_shared_updater_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            dist = Path(directory)
            self.stage(dist, "1.2.3")
            manifest = make_manifest("1.2.3", dist)
            encoded = (json.dumps(manifest, indent=2) + "\n").encode()
            (dist / "manifest.json").write_bytes(encoded)
            args = SimpleNamespace(version="1.2.3", out=dist)
            with patch("macos_candidate_release.require_verified_candidate") as verified, \
                 patch("macos_candidate_release.release_state", return_value={"isDraft": True, "isPrerelease": False, "tagName": "v1.2.3", "assets": []}), \
                 patch("macos_candidate_release.check_remote_digests") as digests, \
                 patch("macos_candidate_release.run") as run, \
                 patch("macos_candidate_release.urllib.request.urlopen", return_value=io.BytesIO(encoded)) as fetch:
                publish(args)
                verified.assert_called_once_with(args, manifest)
                digests.assert_called_once_with("1.2.3", manifest)
                run.assert_called_once()
                command = run.call_args.args
                self.assertIn("--latest=false", command)
                self.assertNotIn("--latest", command)
                self.assertIn("/releases/download/v1.2.3/manifest.json", fetch.call_args.args[0])
                self.assertNotIn("latest", fetch.call_args.args[0])

    def test_exact_graff_release_excludes_dirty_and_dev_builds(self):
        self.assertTrue(has_exact_graff_version("graff v0.0.302.5\n", "0.0.302.5"))
        self.assertFalse(
            has_exact_graff_version("graff v0.0.302.5-1-gabc-dirty\n", "0.0.302.5")
        )
        self.assertFalse(has_exact_graff_version("graff v0.0.302.4\n", "0.0.302.5"))


if __name__ == "__main__":
    unittest.main()
