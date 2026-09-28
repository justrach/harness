#!/bin/sh
# Deploy the edge Worker to edge.codegraff.com from this directory.
#
# The corresponding source archive goes up first (GET /source links to it), so
# it is built from the committed tree: a dirty edge/ would deploy code the
# archive doesn't contain, and is refused.
set -eu
cd "$(dirname "$0")/.."
root=$(git rev-parse --show-toplevel)
if ! git diff --quiet HEAD -- . || [ -n "$(git ls-files --others --exclude-standard -- src)" ]; then
  echo "edge/ has uncommitted changes; commit them before deploying" >&2
  exit 1
fi
commit=$(git rev-parse --short HEAD)
archive=$(mktemp -t harness-edge-source).tar.gz
git -C "$root" archive --format=tar.gz --prefix=harness-edge-source/ -o "$archive" \
  HEAD LICENSE THIRD_PARTY_NOTICES.md edge
npx wrangler r2 object put harness-releases/harness-edge-source-0.1.0.tar.gz --file "$archive" --remote
rm -f "$archive"
npx wrangler deploy --message "edge @ $commit"
