#!/usr/bin/env python3
"""Manual preparation and release tooling for a verified Mac-only Harness candidate.

The macOS app is built, Developer ID signed and notarized on the operator's
Mac (scripts/package-macos.sh). Other platforms and shared update feeds are
excluded from this reconciliation. The steps, each safe to rerun:

  companions  disabled for this Mac-only candidate
  prepare     verify the signed app, updater tarball and DMG; stage every
              asset with its stable aliases and a manifest.json (local only)
  upload      put the staged assets on a draft release (created from
              docs/releases/v<version>.md if missing) and check GitHub's
              digests against the manifest; the release stays a draft
  publish     recheck exact-artifact evidence and digests, publish without
              changing latest, and read the versioned public manifest back
  release     prepare + upload (stops at the draft)

Publication routing is not ready: this helper still requires a remote v* tag,
whose push can trigger the shared multi-platform workflow. The release owner
must choose the tag/publication route before upload, publish or release is used.
This helper is not called by any workflow.

Upload and publish require --verification with Mac QA results for these exact
artifact hashes and the clean, tagged source commit. See macos-reconciliation.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path


REPO = "justrach/harness"
ROOT = Path(__file__).resolve().parent.parent
COMPANION_PLATFORMS = ()
REQUIRED_CHECKS = (
    "launch", "workspace_restore", "session_close_recovery", "provider_switch",
    "browser_inspector", "image_gallery_annotation",
)


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


def companion_names(version: str) -> tuple[str, ...]:
    return tuple(f"harness-{version}-{platform}" for platform in COMPANION_PLATFORMS)


def expected_names(version: str) -> tuple[str, ...]:
    """Only verified macOS arm64 artifacts; no shared-feed companions."""
    return (
        "Harness-macos-arm64.dmg",
        f"harness-{version}-macos-arm64.dmg",
        f"harness-{version}-macos-arm64-app.tar.gz",
    )


ALIASES = {
    "Harness-macos-arm64.dmg": "harness-{version}-macos-arm64.dmg",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def make_manifest(version: str, dist: Path) -> dict:
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is not None, "invalid release version")
    names = expected_names(version)
    require(
        {path.name for path in dist.iterdir()} <= set(names) | {"manifest.json"},
        "staging contains unexpected artifacts; this candidate permits macOS arm64 only",
    )
    for name in names:
        path = dist / name
        require(path.is_file() and path.stat().st_size > 0, f"missing artifact: {name}")
    for alias, target in ALIASES.items():
        require(
            sha256(dist / alias) == sha256(dist / target.format(version=version)),
            f"stable alias {alias} differs from its versioned file",
        )
    return {
        "version": version,
        "files": {name: {"sha256": sha256(dist / name)} for name in sorted(names)},
    }


def validate_verification(evidence: dict, manifest: dict, source_commit: str) -> None:
    """An old preview pass cannot clear different distribution bytes."""
    require(isinstance(evidence, dict), "verification must be a JSON object")
    require(evidence.get("platform") == "macos-arm64", "verification must be for macos-arm64")
    require(evidence.get("version") == manifest["version"], "verification version mismatch")
    require(re.fullmatch(r"[0-9a-f]{40}", source_commit) is not None, "invalid source commit")
    require(evidence.get("sourceCommit") == source_commit, "verification source commit mismatch")
    require(
        evidence.get("artifactSha256") == {name: item["sha256"] for name, item in manifest["files"].items()},
        "verification artifact hashes do not match this candidate",
    )
    checks = evidence.get("checks", {})
    require(isinstance(checks, dict) and all(checks.get(check) is True for check in REQUIRED_CHECKS),
            "required Mac artifact checks are not all complete")
    require(isinstance(evidence.get("reviewer"), str) and bool(evidence["reviewer"].strip()),
            "verification must identify its human reviewer")


def require_verified_candidate(args: argparse.Namespace, manifest: dict) -> None:
    require(args.verification is not None, "--verification is required before upload or publication")
    evidence = json.loads(args.verification.read_text())
    require(not run("git", "-C", ROOT, "status", "--porcelain", "--untracked-files=normal").strip(),
            "publication requires a clean source checkout")
    source = run("git", "-C", ROOT, "rev-parse", "HEAD").strip()
    validate_verification(evidence, manifest, source)
    tag = run("git", "-C", ROOT, "rev-list", "-n", "1", f"v{args.version}").strip()
    require(tag == source, "release tag does not identify the verified source commit")
    remote = run("gh", "api", f"repos/{REPO}/commits/v{args.version}", "--jq", ".sha").strip()
    require(remote == source, "remote release tag does not identify the verified source commit")


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


def preflight() -> None:
    # `tarfile`'s extraction filter needs 3.12, and `xcrun` can't load under
    # Rosetta, so an x86_64 interpreter fails every stapler check.
    require(sys.version_info >= (3, 12), "run with Python 3.12 or newer")
    require(
        platform.machine() == "arm64",
        f"run with an arm64 Python (this one is {platform.machine()})",
    )


def companions(args: argparse.Namespace) -> None:
    raise ValueError("companion releases are disabled: this reconciliation is macOS arm64 only")


def prepare(args: argparse.Namespace) -> None:
    preflight()
    version = args.version
    graff = args.graff_version
    source = args.package_dir
    dmg = source / f"harness-{version}-macos-arm64.dmg"
    app_tarball = source / f"harness-{version}-macos-arm64-app.tar.gz"
    app_hashes = check_bundle(source / "Harness.app", version, graff)
    require(
        check_app_tarball(app_tarball, version, graff) == app_hashes,
        "app tarball contains different executables from the signed app",
    )
    require(
        check_dmg(dmg, version, graff) == app_hashes,
        "DMG contains different executables from the signed app",
    )
    out = args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for path in [dmg, app_tarball]:
        shutil.copy2(path, out / path.name)
    for name in companion_names(version):
        found = sorted(args.other_dir.rglob(name))
        require(found, f"missing companion artifact {name} under {args.other_dir}")
        shutil.copy2(found[0], out / name)
    for alias, target in ALIASES.items():
        shutil.copy2(out / target.format(version=version), out / alias)
    manifest = make_manifest(version, out)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(manifest['files'])} verified assets and manifest at {out}")
    print("No GitHub release or tag was changed.")


def release_state(version: str) -> dict | None:
    try:
        return json.loads(run(
            "gh", "release", "view", f"v{version}", "-R", REPO,
            "--json", "tagName,isDraft,isPrerelease,assets",
        ))
    except subprocess.CalledProcessError:
        return None


def check_remote_digests(version: str, manifest: dict) -> None:
    # Drafts only appear in the list endpoint; one JSON object per line so
    # paginated output stays parseable.
    releases = [
        json.loads(line)
        for line in run(
            "gh", "api", f"repos/{REPO}/releases", "--paginate",
            "--jq", f'.[] | select(.tag_name == "v{version}") | @json',
        ).splitlines()
        if line.strip()
    ]
    require(len(releases) == 1, f"expected one v{version} release, found {len(releases)}")
    remote = {asset["name"]: asset.get("digest") for asset in releases[0]["assets"]}
    require(set(remote) == set(expected_names(version)) | {"manifest.json"},
            "remote release contains unexpected or missing assets; macOS arm64 only")
    manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode()
    require(remote["manifest.json"] == "sha256:" + hashlib.sha256(manifest_bytes).hexdigest(),
            "GitHub's manifest does not match the verified manifest")
    for name, entry in manifest["files"].items():
        require(
            remote.get(name) == f"sha256:{entry['sha256']}",
            f"GitHub's copy of {name} does not match the manifest",
        )


def validate_draft_scope(release: dict | None, version: str) -> None:
    require(release is not None and release.get("tagName") == f"v{version}", "release tag mismatch")
    require(release.get("isDraft") is True and release.get("isPrerelease") is False,
            "publication requires an unpublished stable draft release")
    allowed = set(expected_names(version)) | {"manifest.json"}
    require(all(asset.get("name") in allowed for asset in release.get("assets", [])),
            "existing draft contains artifacts outside this Mac-only candidate")


def upload(args: argparse.Namespace) -> None:
    preflight()
    version = args.version
    dist = args.out
    manifest = json.loads((dist / "manifest.json").read_text())
    require(manifest == make_manifest(version, dist), "manifest does not match staged bytes")
    require_verified_candidate(args, manifest)
    app_hashes = check_app_tarball(
        dist / f"harness-{version}-macos-arm64-app.tar.gz", version, args.graff_version
    )
    require(
        check_dmg(dist / f"harness-{version}-macos-arm64.dmg", version, args.graff_version)
        == app_hashes,
        "DMG and updater tarball contain different executables",
    )
    release = release_state(version)
    if release is None:
        notes = ROOT / f"docs/releases/v{version}.md"
        require(notes.is_file(), f"missing release notes: {notes}")
        run(
            "gh", "release", "create", f"v{version}", "-R", REPO, "--draft",
            "--verify-tag", "--latest=false", "--title", f"Harness v{version} (macOS)", "--notes-file", notes,
        )
        release = release_state(version)
    validate_draft_scope(release, version)
    files = [dist / name for name in expected_names(version)] + [dist / "manifest.json"]
    run("gh", "release", "upload", f"v{version}", *files, "-R", REPO, "--clobber")
    check_remote_digests(version, manifest)
    print(f"Uploaded {len(files)} assets to the draft v{version} release and checked "
          "GitHub's digests; it remains a draft.")


def publish(args: argparse.Namespace) -> None:
    version = args.version
    manifest = json.loads((args.out / "manifest.json").read_text())
    require(manifest == make_manifest(version, args.out), "manifest does not match staged bytes")
    require_verified_candidate(args, manifest)
    release = release_state(version)
    validate_draft_scope(release, version)
    check_remote_digests(version, manifest)
    run("gh", "release", "edit", f"v{version}", "-R", REPO, "--draft=false", "--latest=false")
    url = f"https://github.com/{REPO}/releases/download/v{version}/manifest.json"
    for attempt in range(10):
        with urllib.request.urlopen(url, timeout=30) as response:
            public = json.load(response)
        if public.get("version") == version:
            break
        time.sleep(3)
    require(public == manifest, "the versioned public manifest does not match the staged one")
    print(f"Published Mac-only v{version}; shared latest and updater feeds are unchanged.")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "action", choices=["companions", "prepare", "upload", "publish", "release"]
    )
    parser.add_argument("--version", default=workspace_version())
    parser.add_argument(
        "--graff-version",
        help="the exact graff release bundled in the app (required to verify it)",
    )
    parser.add_argument("--package-dir", type=Path, default=ROOT / "target/package")
    parser.add_argument("--other-dir", type=Path, default=ROOT / "target/release-companions")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--verification", type=Path, help="exact-artifact Mac QA evidence JSON")
    args = parser.parse_args()
    args.out = args.out or ROOT / f"target/macos-candidate-release/v{args.version}"
    steps = {
        "companions": [companions],
        "prepare": [prepare],
        "upload": [upload],
        "publish": [publish],
        "release": [prepare, upload],
    }[args.action]
    try:
        if any(step in (prepare, upload) for step in steps):
            require(args.graff_version is not None, "--graff-version is required")
        for step in steps:
            step(args)
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        detail = getattr(error, "stderr", None)
        print(f"release failed: {error}{': ' + detail.strip() if detail else ''}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
