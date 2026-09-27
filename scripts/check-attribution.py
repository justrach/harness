#!/usr/bin/env python3
"""Reject Claude / Anthropic attribution in commits and PR text.

This repository is public. Commits carry no Claude or Anthropic co-author
trailers, "Generated with Claude Code" footers, claude.ai links, or
noreply@anthropic.com identities. Every other co-author is fine, including
other AI agents such as blackfloofie and Codegraff.

    scripts/check-attribution.py --message-file .git/COMMIT_EDITMSG  # commit-msg hook
    scripts/check-attribution.py --range origin/main..HEAD           # commits in a range
    scripts/check-attribution.py --text-file pr-body.md              # a PR description

Enable the hook once per clone:  git config core.hooksPath .githooks
Exits 1 and names each offending line when it finds attribution.
"""

import argparse
import re
import subprocess
import sys

BANNED = r"anthropic|claude"
PATTERNS = [
    # Co-author trailers naming Claude or an Anthropic noreply address.
    re.compile(rf"^\s*co-authored-by:.*({BANNED})", re.I),
    # "Generated with Claude Code" footers and Claude links.
    re.compile(rf"generated (with|by) \[?({BANNED})", re.I),
    re.compile(r"claude\.(ai|com)/(code|claude-code)", re.I),
]
VENDOR_EMAIL = re.compile(r"noreply@anthropic\.com", re.I)


def offending_lines(text):
    return [line.strip() for line in text.splitlines() if any(p.search(line) for p in PATTERNS)]


def check_range(spec):
    log = subprocess.run(
        ["git", "log", "--format=%H%x00%ae%x00%ce%x00%B%x01", spec],
        capture_output=True, text=True, check=True,
    ).stdout
    problems = []
    for record in filter(str.strip, log.split("\x01")):
        sha, author, committer, body = record.strip("\n").split("\x00", 3)
        found = offending_lines(body)
        found += [f"identity {email}" for email in (author, committer) if VENDOR_EMAIL.search(email)]
        problems += [f"{sha[:10]}: {line}" for line in found]
    return problems


def main():
    ap = argparse.ArgumentParser()
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--message-file")
    group.add_argument("--text-file")
    group.add_argument("--range")
    args = ap.parse_args()
    if args.range:
        problems = check_range(args.range)
    else:
        path = args.message_file or args.text_file
        text = open(path, encoding="utf-8", errors="replace").read()
        # A commit message's comment lines (git's template) are not content.
        if args.message_file:
            text = "\n".join(l for l in text.splitlines() if not l.startswith("#"))
        problems = offending_lines(text)
    if problems:
        print("Remove Claude/Anthropic attribution (public repository):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
