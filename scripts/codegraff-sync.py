#!/usr/bin/env python3
"""Select the current published Codegraff CLI release for GUI packaging."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request


REPO = "justrach/codegraff"
BRANCH = re.compile(r"^refs/heads/release/v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$")
BETA = re.compile(r"^v(\d+\.\d+\.\d+(?:\.\d+)?)-beta\.(\d+)\.(\d+)$")
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$")
ASSETS = {"graff-aarch64-macos.tar.gz", "SHA256SUMS"}


def version_key(match):
    return tuple(int(part or 0) for part in match.groups()[:4])


def parse_refs(lines):
    heads, tags = {}, {}
    for line in lines:
        sha, ref = line.split("\t", 1)
        if BRANCH.fullmatch(ref):
            heads[ref] = sha
        elif ref.startswith("refs/tags/"):
            tag = ref.removeprefix("refs/tags/")
            # Annotated tags expose both the tag object and its commit.
            name = tag.removesuffix("^{}")
            if tag.endswith("^{}") or name not in tags:
                tags[name] = sha
    return heads, tags


def select_beta(heads, tags, releases):
    if not heads:
        raise ValueError("no numeric Codegraff release branch found")
    branch = max(heads, key=lambda name: (version_key(BRANCH.fullmatch(name)), name))
    version = branch.removeprefix("refs/heads/release/v")
    commit = heads[branch]
    candidates = []
    for release in releases:
        tag = release.get("tag_name", "")
        match = BETA.fullmatch(tag)
        if (not match or match[1] != version or release.get("draft")
                or not release.get("prerelease") or tags.get(tag) != commit):
            continue
        if not ASSETS.issubset({asset["name"] for asset in release.get("assets", [])}):
            continue
        candidates.append((int(match[2]), int(match[3]), tag))
    if not candidates:
        return None
    _, _, tag = max(candidates)
    return {"branch": branch.removeprefix("refs/heads/"), "sha": commit, "tag": tag}


def select_stable(tags, releases):
    candidates = []
    for release in releases:
        tag = release.get("tag_name", "")
        match = STABLE.fullmatch(tag)
        if (not match or release.get("draft") or release.get("prerelease")
                or tag not in tags):
            continue
        if not ASSETS.issubset({asset["name"] for asset in release.get("assets", [])}):
            continue
        candidates.append((version_key(match), tag))
    if not candidates:
        return None
    _, tag = max(candidates)
    return {"branch": "", "sha": tags[tag], "tag": tag}


def github_releases():
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "harness-beta-sync"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    for page in range(1, 21):
        url = f"https://api.github.com/repos/{REPO}/releases?per_page=100&page={page}"
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
            batch = json.load(response)
        yield from batch
        if len(batch) < 100:
            return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", choices=("beta", "stable"), default="beta")
    args = parser.parse_args()
    refs = subprocess.run(
        ["git", "ls-remote", "--heads", "--tags", f"https://github.com/{REPO}.git"],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    heads, tags = parse_refs(refs)
    releases = list(github_releases())
    chosen = (select_beta(heads, tags, releases) if args.channel == "beta"
              else select_stable(tags, releases))
    if not chosen:
        print(f"No complete published {args.channel} release available")
        return
    expected = {
        "branch": os.environ.get("EXPECTED_BRANCH"),
        "sha": os.environ.get("EXPECTED_SHA"),
        "tag": os.environ.get("EXPECTED_TAG"),
    }
    if any(value and chosen[key] != value for key, value in expected.items()):
        print(f"Dispatch does not match the current published {args.channel} release; skipped")
        return
    for key, value in chosen.items():
        print(f"{key}={value}")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with Path(output).open("a", encoding="utf-8") as stream:
            for key, value in chosen.items():
                stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
