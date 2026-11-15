#!/usr/bin/env python3
"""Unit tests for scripts/ci-changed-scopes.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import unittest

SCRIPT_PATH = Path(__file__).resolve().parent / "ci-changed-scopes.py"
SPEC = importlib.util.spec_from_file_location("ci_changed_scopes", SCRIPT_PATH)
assert SPEC and SPEC.loader
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class CiChangedScopesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parent.parent
        self.ws_crates = mod.discover_workspace_crate_names(self.repo_root)
        self.assertGreaterEqual(len(self.ws_crates), 15)
        self.assertIn("harness", self.ws_crates)
        self.assertIn("harness-engine", self.ws_crates)

    def test_cargo_toml_version_only_detection(self) -> None:
        base = '[workspace]\nmembers = ["crates/engine", "apps/harness"]\n[workspace.package]\nversion = "0.2.202"\nedition = "2024"\n'
        same_bump = '[workspace]\nmembers = ["crates/engine", "apps/harness"]\n[workspace.package]\nversion = "0.2.203"\nedition = "2024"\n'
        dep_change = base + '\n[workspace.dependencies]\nanyhow = "1.0"\n'
        self.assertTrue(mod.is_version_only_cargo_toml(base, same_bump))
        self.assertFalse(mod.is_version_only_cargo_toml(base, dep_change))
        self.assertFalse(mod.is_version_only_cargo_toml(base, "not = [valid toml"))

    def test_cargo_lock_version_only_detection(self) -> None:
        base = (
            'version = 4\n\n'
            '[[package]]\nname = "harness"\nversion = "0.2.202"\ndependencies = ["harness-engine"]\n\n'
            '[[package]]\nname = "anyhow"\nversion = "1.0.95"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "abc"\n'
        )
        ws_bump = (
            'version = 4\n\n'
            '[[package]]\nname = "harness"\nversion = "0.2.203"\ndependencies = ["harness-engine"]\n\n'
            '[[package]]\nname = "anyhow"\nversion = "1.0.95"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "abc"\n'
        )
        ext_bump = (
            'version = 4\n\n'
            '[[package]]\nname = "harness"\nversion = "0.2.202"\ndependencies = ["harness-engine"]\n\n'
            '[[package]]\nname = "anyhow"\nversion = "1.0.96"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "def"\n'
        )
        self.assertTrue(mod.is_version_only_cargo_lock(base, ws_bump, self.ws_crates))
        self.assertFalse(mod.is_version_only_cargo_lock(base, ext_bump, self.ws_crates))

    def test_pure_nano_pr_skips_all_rust_and_android(self) -> None:
        s = mod.classify_scopes(["apps/nano/src/member_card.zig", "apps/nano/assets/cards/daruma-zen/near.png"], False)
        self.assertTrue(s["nano_ui"])
        self.assertTrue(s["win_ui"])
        self.assertTrue(s["ui_macos_job"])
        for k in ("rust_core", "ui_session_sync", "ui_macos_rust", "win_app", "win_engine", "cursor_rust", "preview_rust", "preview_edge", "android"):
            self.assertFalse(s[k], f"expected {k}=False")

    def test_nano_release_pr_version_bump_skips_rust(self) -> None:
        s = mod.classify_scopes(
            ["Cargo.toml", "Cargo.lock", "docs/releases/v0.2.203.md", "apps/nano/src/member_card.zig"],
            cargo_meaningful=False,
        )
        self.assertTrue(s["nano_ui"])
        self.assertTrue(s["win_ui"])
        self.assertTrue(s["ui_macos_job"])
        for k in ("rust_core", "ui_session_sync", "ui_macos_rust", "win_app", "win_engine", "cursor_rust", "preview_rust", "android"):
            self.assertFalse(s[k], f"expected {k}=False")

    def test_meaningful_cargo_change_enables_all_rust_and_android(self) -> None:
        s = mod.classify_scopes(["Cargo.toml", "Cargo.lock"], cargo_meaningful=True)
        for k in ("rust_core", "ui_session_sync", "ui_macos_rust", "ui_macos_job", "win_app", "win_engine", "cursor_rust", "preview_rust", "android"):
            self.assertTrue(s[k], f"expected {k}=True")
        self.assertFalse(s["nano_ui"])
        self.assertFalse(s["win_ui"])

    def test_crates_engine_enables_engine_scopes_not_preview_or_android(self) -> None:
        s = mod.classify_scopes(["crates/engine/src/lib.rs"], False)
        for k in ("rust_core", "ui_session_sync", "ui_macos_rust", "ui_macos_job", "win_app", "win_engine", "cursor_rust"):
            self.assertTrue(s[k], f"expected {k}=True")
        for k in ("nano_ui", "win_ui", "preview_rust", "preview_edge", "android"):
            self.assertFalse(s[k], f"expected {k}=False")

    def test_crates_proto_enables_preview_and_android(self) -> None:
        s = mod.classify_scopes(["crates/proto/src/lib.rs"], False)
        for k in ("rust_core", "preview_rust", "android"):
            self.assertTrue(s[k], f"expected {k}=True")

    def test_workflow_only_pr_skips_rust_and_android(self) -> None:
        s = mod.classify_scopes(
            [".github/workflows/windows.yml", ".github/workflows/ui-tests.yml", "scripts/ci-changed-scopes.py"],
            False,
        )
        self.assertTrue(s["nano_ui"])
        self.assertTrue(s["win_ui"])
        for k in ("rust_core", "ui_session_sync", "ui_macos_rust", "win_app", "win_engine", "cursor_rust", "preview_rust", "android"):
            self.assertFalse(s[k], f"expected {k}=False")

    def test_workflow_dispatch_and_missing_base_fail_open(self) -> None:
        for key, val in mod.detect_from_git(self.repo_root, "workflow_dispatch", "HEAD~1", "HEAD").items():
            self.assertTrue(val, f"expected fail-open True for {key}")
        for key, val in mod.detect_from_git(self.repo_root, "pull_request", "0" * 40, "HEAD").items():
            self.assertTrue(val, f"expected fail-open True for {key}")

    def test_actual_v02203_release_commit_if_present(self) -> None:
        probe = subprocess.run(
            ["git", "-C", str(self.repo_root), "cat-file", "-e", "66808c553^{commit}"],
            capture_output=True,
            check=False,
        )
        if probe.returncode != 0:
            self.skipTest("v0.2.203 commit not in shallow checkout")
        s = mod.detect_from_git(self.repo_root, "pull_request", "66808c553^", "66808c553")
        self.assertTrue(s["nano_ui"])
        self.assertTrue(s["win_ui"])
        self.assertTrue(s["ui_macos_job"])
        for k in ("rust_core", "ui_session_sync", "ui_macos_rust", "win_app", "win_engine", "cursor_rust", "preview_rust", "android"):
            self.assertFalse(s[k], f"expected v0.2.203 release to skip {k}")


if __name__ == "__main__":
    unittest.main()
