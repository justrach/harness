#!/usr/bin/env python3
"""Offline selection tests for Codegraff beta synchronization."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("codegraff_sync", Path(__file__).with_name("codegraff-sync.py"))
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)


def release(tag, assets=("graff-aarch64-macos.tar.gz", "SHA256SUMS")):
    return {"tag_name": tag, "prerelease": True, "draft": False,
            "assets": [{"name": name} for name in assets]}


class BetaSelectionTest(unittest.TestCase):
    def test_newest_numeric_branch_and_exact_commit(self):
        heads = {"refs/heads/release/v0.0.9": "old", "refs/heads/release/v0.0.10": "current"}
        tags = {"v0.0.10-beta.2.1": "stale", "v0.0.10-beta.3.1": "current",
                "v0.0.9-beta.99.1": "old"}
        self.assertEqual(beta.select_beta(heads, tags, list(map(release, tags))), {
            "branch": "release/v0.0.10", "sha": "current", "tag": "v0.0.10-beta.3.1"})

    def test_fourth_component_and_complete_assets(self):
        heads = {"refs/heads/release/v0.0.302": "a", "refs/heads/release/v0.0.302.4": "b"}
        tags = {"v0.0.302.4-beta.1.1": "b", "v0.0.302-beta.2.1": "a"}
        releases = [release("v0.0.302.4-beta.1.1", ("SHA256SUMS",)),
                    release("v0.0.302-beta.2.1")]
        self.assertIsNone(beta.select_beta(heads, tags, releases))

    def test_annotated_tag_uses_peeled_commit(self):
        heads, tags = beta.parse_refs([
            "head\trefs/heads/release/v1.2.3",
            "object\trefs/tags/v1.2.3-beta.1.1",
            "head\trefs/tags/v1.2.3-beta.1.1^{}",
        ])
        self.assertEqual(beta.select_beta(heads, tags, [release("v1.2.3-beta.1.1")])["sha"], "head")

    def test_stable_ignores_draft_prerelease_and_incomplete_assets(self):
        tags = {"v0.0.9": "old", "v0.0.10": "current", "v0.0.11": "next",
                "v0.0.12": "draft", "v0.0.13": "missing"}
        releases = [
            {**release("v0.0.9"), "prerelease": False},
            {**release("v0.0.10"), "prerelease": False},
            release("v0.0.11"),
            {**release("v0.0.12"), "draft": True, "prerelease": False},
            {**release("v0.0.13", ("SHA256SUMS",)), "prerelease": False},
        ]
        self.assertEqual(beta.select_stable(tags, releases), {
            "branch": "", "sha": "current", "tag": "v0.0.10"})

    def test_stable_numeric_fourth_component(self):
        tags = {"v0.0.302": "old", "v0.0.302.4": "current", "v0.0.99": "older"}
        releases = [{**release(tag), "prerelease": False} for tag in tags]
        self.assertEqual(beta.select_stable(tags, releases)["tag"], "v0.0.302.4")


if __name__ == "__main__":
    unittest.main()
