#!/usr/bin/env python3
"""Rename the product in the Codex TUI's user-visible text: "Codex" -> "Codegraff".

Usage: rebrand.py <codex-rs/tui dir>

Idempotent, and meant to be re-run after bumping CODEX_REV (setup.sh does).
Only the capitalised product name is touched, and only inside Rust string
literals (comments, identifiers, `codex` commands/paths/URLs stay as upstream).
Test files are rewritten too so their expectations keep matching the code.
"""
import os
import re
import sys

BRAND = "Codegraff"
WORD = re.compile(r"\bCodex\b")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
# Literals that are protocol or filesystem text rather than display text.
KEEP = ("My request for Codex", "OpenAI\\\\Codex", "OpenAI\\Codex")
# Tips that only make sense for OpenAI's Codex.
DROP_TIPS = ("openaiDeveloperDocs", "community.openai.com", "`codex resume`", "signed in with ChatGPT")


def rebrand_text(text: str) -> str:
    text = text.replace("OpenAI Codex", BRAND).replace("Codex CLI", BRAND)
    return WORD.sub(BRAND, text)


def rebrand_line(line: str) -> str:
    if line.lstrip().startswith("//"):
        return line

    def swap(match: re.Match) -> str:
        body = match.group(1)
        if any(k in body for k in KEEP) or not (WORD.search(body) or "OpenAI Codex" in body):
            return match.group(0)
        return '"' + rebrand_text(body) + '"'

    return LITERAL.sub(swap, line)


def process_rust(root: str) -> int:
    changed = 0
    for base, _, files in os.walk(os.path.join(root, "src")):
        if "snapshots" in base:
            continue
        for name in files:
            if not name.endswith(".rs"):
                continue
            path = os.path.join(base, name)
            with open(path, encoding="utf-8", errors="surrogateescape") as f:
                old = f.read()
            new = "".join(rebrand_line(line) for line in old.splitlines(keepends=True))
            if new != old:
                with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(new)
                changed += 1
    return changed


def process_tips(root: str) -> None:
    path = os.path.join(root, "assets", "tooltips.txt")
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines(keepends=True)
    kept = [l for l in lines if l.startswith("#") or not any(d in l for d in DROP_TIPS)]
    text = "".join(rebrand_text(l) if not l.startswith("#") else l for l in kept)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def process_title(root: str) -> None:
    """The header shows the version; a source build reports 0.0.0, so drop it."""
    path = os.path.join(root, "src", "history_cell", "session.rs")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = text.replace('        format!(" (v{version})").dim(),\n', "")
    text = text.replace("pub(crate) fn codex_title(version: &str)", "pub(crate) fn codex_title(_version: &str)")
    text = text.replace(f'Line::from(format!("{BRAND} (v{{}})", self.version)),', f'Line::from("{BRAND}"),')
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def process_exit_hints(root: str) -> None:
    """The exit message tells people to run `codex --remote ... resume`, a command that
    does not exist here (and the bridge stops with run.sh), so drop those hints."""
    path = os.path.join(root, "src", "app", "exit_summary.rs")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    start = text.find("            let mut resume_command = disconnect.command.clone();")
    end = text.find("            if !self.token_usage.is_zero() {\n                let usage", start)
    if start != -1 and end != -1:
        text = text[:start] + text[end:]
    text = text.replace(
        "} else if let Some(thread) = self.resume_hint {",
        "} else if let Some(thread) = self.resume_hint.filter(|_| false) {",
    )
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


if __name__ == "__main__":
    tui = sys.argv[1]
    print(f"rewrote {process_rust(tui)} Rust files")
    process_tips(tui)
    process_title(tui)
    process_exit_hints(tui)
