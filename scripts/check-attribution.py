#!/usr/bin/env python3
"""Reject AI-assistant and model-vendor attribution in commits and PR text.

This repository is public. Commits carry only their human author: no
assistant co-author trailers, "generated with" footers, or vendor noreply
identities. Human co-authors (including Codegraff) are fine.

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

VENDORS = r"anthropic|claude|openai|chatgpt|gpt-\d|codex|copilot|gemini|cursor ?agent|devin"
PATTERNS = [
    # Co-author trailers naming an assistant or a vendor noreply address.
    re.compile(rf"^\s*co-authored-by:.*({VENDORS})", re.I),
    # "Generated with …" footers and assistant links.
    re.compile(r"generated (with|by) \[?(claude|chatgpt|codex|copilot|gemini|cursor)", re.I),
    re.compile(r"🤖\s*generated", re.I),
    re.compile(r"claude\.(ai|com)/(code|claude-code)", re.I),
]
VENDOR_EMAIL = re.compile(r"noreply@(anthropic|openai)\.com", re.I)


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
        print("Remove AI-assistant/vendor attribution (public repository):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
