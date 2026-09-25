#!/usr/bin/env python3
"""Prepare and upload a verified stable Harness release from signed artifacts.

The prepare step only writes to an output directory. The upload step accepts
an existing draft GitHub release and leaves it as a draft.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


REPO = "justrach/harness"
ROOT = Path(__file__).resolve().parent.parent


def run(*args: str | Path) -> str:
    result = subprocess.run(
        [str(arg) for arg in args], check=True, text=True, capture_output=True
    )
    return result.stdout + result.stderr


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def workspace_version() -> str:
    text = (ROOT / "Cargo.toml").read_text()
    match = re.search(r'^version\s*=\s*"([0-9]+(?:\.[0-9]+){2})"', text, re.M)
    require(match is not None, "Cargo.toml has no workspace version")
    return match.group(1)


def expected_names(version: str) -> tuple[str, ...]:
    return (
        "Harness-macos-arm64.dmg",
        f"harness-{version}-macos-arm64.dmg",
        f"harness-{version}-macos-arm64-app.tar.gz",
        f"zeron-{version}-linux-aarch64.tar.gz",
        f"zeron-{version}-linux-x86_64.tar.gz",
        f"zeron-{version}-windows-x86_64.exe",
        f"zeron-{version}-windows-x86_64.zip",
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_manifest(version: str, dist: Path) -> dict:
    names = expected_names(version)
    for name in names:
        path = dist / name
        require(path.is_file() and path.stat().st_size > 0, f"missing artifact: {name}")
    require(
        sha256(dist / names[0]) == sha256(dist / names[1]),
        "stable DMG alias differs from the versioned DMG",
    )
    return {
        "version": version,
        "files": {name: {"sha256": sha256(dist / name)} for name in names},
    }


def check_developer_id(path: Path) -> None:
    run("codesign", "--verify", "--strict", "--verbose=2", path)
    details = run("codesign", "--display", "--verbose=4", path)
    require("Authority=Developer ID Application" in details, f"{path} lacks Developer ID signing")
    require("Timestamp=" in details, f"{path} lacks a secure timestamp")
    require("runtime" in details, f"{path} lacks hardened runtime")


def check_graff_version(bundle: Path, expected: str) -> None:
    binary = bundle / "Contents/Resources/bin/graff"
    require(binary.is_file(), f"{bundle} does not bundle graff")
    check_developer_id(binary)
    output = run(binary, "--version")
    require(
        has_exact_graff_version(output, expected),
        f"bundled graff is not exactly {expected}: {output.strip()}",
    )


def has_exact_graff_version(output: str, expected: str) -> bool:
    versions = re.findall(r"\bv?\d+(?:\.\d+){2,3}(?:[-+][A-Za-z0-9.-]+)?", output)
    return any(version.removeprefix("v") == expected for version in versions)


def bundle_hashes(bundle: Path) -> tuple[str, str]:
    return (
        sha256(bundle / "Contents/MacOS/harness"),
        sha256(bundle / "Contents/Resources/bin/graff"),
    )


def check_bundle(bundle: Path, version: str, graff_version: str) -> tuple[str, str]:
    require(bundle.is_dir(), f"missing app bundle: {bundle}")
    actual = run(
        "plutil", "-extract", "CFBundleShortVersionString", "raw",
        bundle / "Contents/Info.plist",
    ).strip()
    require(actual == version, f"app version {actual} differs from {version}")
    bundle_id = run(
        "plutil", "-extract", "CFBundleIdentifier", "raw",
        bundle / "Contents/Info.plist",
    ).strip()
    require(bundle_id == "harness.codegraff.app", f"unexpected app ID: {bundle_id}")
    check_developer_id(bundle)
    run("xcrun", "stapler", "validate", bundle)
    check_graff_version(bundle, graff_version)
    return bundle_hashes(bundle)


def check_app_tarball(
    archive: Path, version: str, graff_version: str
) -> tuple[str, str]:
    with tempfile.TemporaryDirectory(prefix="harness-release-check-") as temp:
        with tarfile.open(archive, "r:gz") as stream:
            members = stream.getmembers()
            require(members, f"empty app archive: {archive}")
            require(
                all(
                    member.name == "Harness.app"
                    or member.name.startswith("Harness.app/")
                    for member in members
                ),
                "app archive contains paths outside Harness.app",
            )
            stream.extractall(temp, filter="data")
        return check_bundle(Path(temp) / "Harness.app", version, graff_version)


def check_dmg(dmg: Path, version: str, graff_version: str) -> tuple[str, str]:
    require(dmg.is_file(), f"missing DMG: {dmg}")
    run("hdiutil", "verify", dmg)
    run("codesign", "--verify", "--strict", "--verbose=2", dmg)
    details = run("codesign", "--display", "--verbose=4", dmg)
    require("Authority=Developer ID Application" in details, "DMG lacks Developer ID signing")
    require("Timestamp=" in details, "DMG lacks a secure timestamp")
    run("xcrun", "stapler", "validate", dmg)
    with tempfile.TemporaryDirectory(prefix="harness-dmg-check-") as temp:
        mount = Path(temp) / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
        try:
            return check_bundle(mount / "Harness.app", version, graff_version)
        finally:
            run("hdiutil", "detach", mount)


def prepare(args: argparse.Namespace) -> None:
    version = workspace_version()
    require(args.version == "0.2.85", "this helper is for Harness v0.2.85 only")
    require(version == args.version, f"Cargo.toml is {version}, expected {args.version}")
    require(args.graff_version == "0.0.302.5", "v0.2.85 requires graff 0.0.302.5")
    source = args.package_dir
    dmg = source / f"harness-{version}-macos-arm64.dmg"
    app_tarball = source / f"harness-{version}-macos-arm64-app.tar.gz"
    app_hashes = check_bundle(source / "Harness.app", version, args.graff_version)
    require(
        check_app_tarball(app_tarball, version, args.graff_version) == app_hashes,
        "app tarball contains different executables from the signed app",
    )
    require(
        check_dmg(dmg, version, args.graff_version) == app_hashes,
        "DMG contains different executables from the signed app",
    )
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    for path in [dmg, app_tarball]:
        shutil.copy2(path, out / path.name)
    shutil.copy2(dmg, out / "Harness-macos-arm64.dmg")
    for name in expected_names(version)[3:]:
        source_path = args.other_dir / name
        require(source_path.is_file(), f"missing companion artifact: {source_path}")
        shutil.copy2(source_path, out / name)
    manifest = make_manifest(version, out)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(manifest['files'])} verified assets and manifest at {out}")
    print("No GitHub release or tag was changed.")


def upload(args: argparse.Namespace) -> None:
    version = workspace_version()
    require(args.version == "0.2.85", "this helper is for Harness v0.2.85 only")
    require(version == args.version, f"Cargo.toml is {version}, expected {args.version}")
    require(args.graff_version == "0.0.302.5", "v0.2.85 requires graff 0.0.302.5")
    dist = args.out
    manifest = json.loads((dist / "manifest.json").read_text())
    require(manifest == make_manifest(version, dist), "manifest does not match staged bytes")
    app_hashes = check_app_tarball(
        dist / f"harness-{version}-macos-arm64-app.tar.gz", version, args.graff_version
    )
    require(
        check_dmg(dist / f"harness-{version}-macos-arm64.dmg", version, args.graff_version)
        == app_hashes,
        "DMG and updater tarball contain different executables",
    )
    release = json.loads(run("gh", "release", "view", f"v{version}", "-R", REPO,
                             "--json", "tagName,isDraft,isPrerelease"))
    require(release["tagName"] == f"v{version}", "release tag mismatch")
    require(release["isDraft"] and not release["isPrerelease"],
            "upload requires an unpublished stable draft release")
    files = [dist / name for name in expected_names(version)] + [dist / "manifest.json"]
    run("gh", "release", "upload", f"v{version}", *files, "-R", REPO, "--clobber")
    print(f"Uploaded {len(files)} assets to the draft v{version} release; it remains a draft.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "upload"])
    parser.add_argument("--version", default="0.2.85")
    parser.add_argument("--graff-version", default="0.0.302.5")
    parser.add_argument("--package-dir", type=Path, default=ROOT / "target/package")
    parser.add_argument("--other-dir", type=Path, default=ROOT / "target/release-companions")
    parser.add_argument("--out", type=Path, default=ROOT / "target/stable-release/v0.2.85")
    args = parser.parse_args()
    try:
        (prepare if args.action == "prepare" else upload)(args)
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"release preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
