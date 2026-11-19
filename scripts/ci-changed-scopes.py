#!/usr/bin/env python3
"""Determine which GitHub Actions CI scopes must run for a push or pull request.

Recognises pure version bumps in root Cargo.toml ([workspace.package].version /
[package].version) and Cargo.lock (version bumps of workspace crates with no
external `source`) so non-Rust PRs and Nano-only `release/v*` PRs skip heavy
Rust and Android NDK suites while still running Zig `apps/nano` UI tests.
Fails open (returns `true` for all scopes) whenever git metadata is missing or
cannot be parsed safely.
"""

from __future__ import annotations

import argparse
import copy
from fnmatch import fnmatch
import os
from pathlib import Path
import subprocess
import sys
import tomllib

SCOPE_KEYS = (
    "rust_core",
    "nano_ui",
    "ui_session_sync",
    "ui_macos_rust",
    "ui_macos_job",
    "win_ui",
    "win_app",
    "win_engine",
    "cursor_rust",
    "preview_rust",
    "preview_edge",
    "android",
)


def all_true_scopes() -> dict[str, bool]:
    return {key: True for key in SCOPE_KEYS}


def discover_workspace_crate_names(repo_root: Path) -> set[str]:
    """Read workspace member `[package].name` entries from root Cargo.toml."""
    root_toml = repo_root / "Cargo.toml"
    if not root_toml.is_file():
        return set()
    try:
        root_data = tomllib.loads(root_toml.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return set()
    members = root_data.get("workspace", {}).get("members", [])
    names: set[str] = set()
    for member in members:
        if not isinstance(member, str):
            continue
        member_toml = repo_root / member / "Cargo.toml"
        if not member_toml.is_file():
            continue
        try:
            member_data = tomllib.loads(member_toml.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError):
            continue
        name = member_data.get("package", {}).get("name")
        if isinstance(name, str) and name:
            names.add(name)
    return names


def _normalize_cargo_toml(data: dict) -> dict:
    out = copy.deepcopy(data)
    ws_pkg = out.get("workspace", {}).get("package")
    if isinstance(ws_pkg, dict) and "version" in ws_pkg:
        ws_pkg["version"] = "0.0.0"
    pkg = out.get("package")
    if isinstance(pkg, dict) and "version" in pkg:
        pkg["version"] = "0.0.0"
    return out


def is_version_only_cargo_toml(base_text: str, head_text: str) -> bool:
    """Return True iff Cargo.toml differs only in package / workspace.package version."""
    try:
        base_data = tomllib.loads(base_text)
        head_data = tomllib.loads(head_text)
    except tomllib.TOMLDecodeError:
        return False
    return _normalize_cargo_toml(base_data) == _normalize_cargo_toml(head_data)


def _normalize_cargo_lock(data: dict, workspace_crate_names: set[str]) -> dict:
    out = copy.deepcopy(data)
    pkgs = out.get("package")
    if isinstance(pkgs, list):
        for pkg in pkgs:
            if (
                isinstance(pkg, dict)
                and "source" not in pkg
                and pkg.get("name") in workspace_crate_names
                and "version" in pkg
            ):
                pkg["version"] = "0.0.0"
    return out


def is_version_only_cargo_lock(
    base_text: str, head_text: str, workspace_crate_names: set[str]
) -> bool:
    """Return True iff Cargo.lock differs only in workspace crate versions."""
    if not workspace_crate_names:
        return False
    try:
        base_data = tomllib.loads(base_text)
        head_data = tomllib.loads(head_text)
    except tomllib.TOMLDecodeError:
        return False
    return _normalize_cargo_lock(base_data, workspace_crate_names) == _normalize_cargo_lock(
        head_data, workspace_crate_names
    )


def classify_scopes(changed_files: list[str], cargo_meaningful: bool) -> dict[str, bool]:
    """Compute per-workflow/job booleans from changed paths and Cargo change significance."""
    if not changed_files:
        return all_true_scopes()

    paths = [p.removeprefix("./") for p in changed_files if p and p.strip()]
    if not paths:
        return all_true_scopes()

    def any_prefix(prefixes: tuple[str, ...]) -> bool:
        return any(p.startswith(prefixes) for p in paths)

    def any_exact(names: set[str]) -> bool:
        return any(p in names for p in paths)

    rust_core = cargo_meaningful or any_prefix(
        ("crates/", "apps/harness/", "protocol/", ".cargo/")
    ) or any_exact({"rust-toolchain.toml"})

    nano_paths = any_prefix(("apps/nano/", "apps/parity/", "protocol/desktop/"))
    scope_scripts = {"scripts/ci-changed-scopes.py", "scripts/test-ci-changed-scopes.py"}

    nano_ui = nano_paths or any_exact({".github/workflows/ui-tests.yml", *scope_scripts})
    ui_session_sync = rust_core or any_exact({"scripts/heavy-build.sh", "scripts/test-heavy-build.py"})
    ui_macos_rust = rust_core or any_exact({"dist/macos/Info.plist"})
    ui_macos_job = ui_macos_rust or nano_paths

    windows_ci = any_exact({".github/workflows/windows.yml", *scope_scripts})
    win_ui = nano_paths or windows_ci
    win_app = (
        rust_core
        or windows_ci
        or any_prefix(("dist/windows/", ".github/actions/windows-rust/"))
        or any(
            fnmatch(p, "scripts/package-windows.ps1") or fnmatch(p, "scripts/test-windows-*.ps1")
            for p in paths
        )
    )
    win_engine = rust_core or windows_ci or any_prefix((".github/actions/windows-rust/",))

    cursor_rust = (
        cargo_meaningful
        or any_prefix(("crates/harness/", "crates/doc/", "crates/engine/"))
        or any(fnmatch(p, "scripts/*cursor-sdk*") for p in paths)
    )

    preview_rust = cargo_meaningful or any_prefix(("crates/preview/", "crates/proto/", "protocol/"))
    preview_edge = any_prefix(("edge/", "protocol/"))

    android = (
        cargo_meaningful
        or any_exact({"rust-toolchain.toml", "apps/ios/Harness/Theme/themes.json"})
        or any_prefix(
            (
                "apps/android/",
                "apps/parity/",
                "crates/mobile/",
                "crates/doc/",
                "crates/sync/",
                "crates/proto/",
                ".github/actions/android-native/",
            )
        )
    )

    return {
        "rust_core": rust_core,
        "nano_ui": nano_ui,
        "ui_session_sync": ui_session_sync,
        "ui_macos_rust": ui_macos_rust,
        "ui_macos_job": ui_macos_job,
        "win_ui": win_ui,
        "win_app": win_app,
        "win_engine": win_engine,
        "cursor_rust": cursor_rust,
        "preview_rust": preview_rust,
        "preview_edge": preview_edge,
        "android": android,
    }


def _git_ok(repo_root: Path, *args: str) -> str | None:
    proc = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def _commit_exists(repo_root: Path, rev: str) -> bool:
    if not rev or rev == ("0" * 40):
        return False
    return _git_ok(repo_root, "cat-file", "-e", f"{rev}^{{commit}}") is not None


def detect_from_git(repo_root: Path, event_name: str, base: str, head: str) -> dict[str, bool]:
    """Compute CI scopes from git base..head commits; fail open if unavailable."""
    if event_name not in ("pull_request", "push"):
        return all_true_scopes()
    if not (_commit_exists(repo_root, base) and _commit_exists(repo_root, head)):
        return all_true_scopes()

    diff_out = _git_ok(repo_root, "diff", "--name-only", base, head)
    if diff_out is None:
        return all_true_scopes()
    changed_files = [line.strip() for line in diff_out.splitlines() if line.strip()]
    if not changed_files:
        return all_true_scopes()

    cargo_meaningful = False
    path_set = set(changed_files)
    if "Cargo.toml" in path_set:
        b_toml = _git_ok(repo_root, "show", f"{base}:Cargo.toml")
        h_toml = _git_ok(repo_root, "show", f"{head}:Cargo.toml")
        if b_toml is None or h_toml is None or not is_version_only_cargo_toml(b_toml, h_toml):
            cargo_meaningful = True

    if not cargo_meaningful and "Cargo.lock" in path_set:
        b_lock = _git_ok(repo_root, "show", f"{base}:Cargo.lock")
        h_lock = _git_ok(repo_root, "show", f"{head}:Cargo.lock")
        ws_crates = discover_workspace_crate_names(repo_root)
        if b_lock is None or h_lock is None or not is_version_only_cargo_lock(b_lock, h_lock, ws_crates):
            cargo_meaningful = True

    return classify_scopes(changed_files, cargo_meaningful)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT", ""))
    args = parser.parse_args(argv)

    scopes = detect_from_git(Path(args.repo_root), args.event_name, args.base, args.head)
    lines = [f"{k}={'true' if scopes[k] else 'false'}" for k in SCOPE_KEYS]
    sys.stdout.write("\n".join(lines) + "\n")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
