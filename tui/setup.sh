#!/bin/sh
# Fetch openai/codex at the pinned revision into tui/codex (gitignored).
set -eu
cd "$(dirname "$0")"
rev=$(cat CODEX_REV)
if [ ! -d codex/.git ]; then
  git clone --filter=blob:none https://github.com/openai/codex codex
fi
git -C codex fetch --depth 1 origin "$rev" 2>/dev/null || git -C codex fetch origin
git -C codex checkout --quiet "$rev"
# Apply our patches once; a patch that reverses cleanly is already applied.
for patch in "$PWD"/patches/*.patch; do
  if git -C codex apply --check --reverse "$patch" 2>/dev/null; then
    echo "already applied: $(basename "$patch")"
  else
    git -C codex apply "$patch"
    echo "applied: $(basename "$patch")"
  fi
done
# Product name in user-visible text (idempotent; safe to re-run after a revision bump).
python3 tools/rebrand.py codex/codex-rs/tui
echo "tui/codex at $(git -C codex rev-parse --short HEAD)"
