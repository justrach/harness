# Harness

## Verification gates

Narrow gates for ACP adapter work (the work tree is often dirty — never run
`cargo fmt` repo-wide; format-check only the files you touched and disable
child-module traversal):

```bash
cargo test -p harness-adapters --test acp devin_        # Devin ACP integration tests
cargo test -p harness-adapters --lib acp::devin_models  # pure resolver/catalog tests
rustfmt --edition 2024 --config skip_children=true --check <touched .rs files>
```

`crates/harness/src/acp/mod.rs` has existing formatting differences. Leave
unrelated formatting unchanged and distinguish those differences from new ones.

Adding a composer slash command (a `WorkspaceCommand` variant) changes the row
counts asserted in `workspace_commands_preserve_native_commands_and_avoid_collisions`
(`crates/ui/src/composer.rs`): with a chat, and without one if the command is
offered in drafts. Update them in the same change and run
`cargo test -p harness-ui --lib workspace_commands`.

## Tests every change carries

- **Reproduce first.** A bug fix comes with a test that fails on `main` and
  passes with the fix. The PR names the test and says it fails on `main`. If
  the cause can't be shown with evidence, report what was found rather than
  shipping a guess.
- **Don't redo merged or open work.** Before starting, search open and merged
  PRs and the issue's history (a closed issue may have been reopened as a
  recurrence). If a PR already covers it, build on that PR instead.
- **Synthetic data only.** Never read a person's Harness data, journals or logs
  to build a test.
- **Pull rules into pure functions** (for example `next_row_cursor` in Rust and
  `chatNextRowCursor` in Swift), so a test or a shared vector can call them.
- **Rules several implementations share live as data:**
  - the chat2 sync protocol (frame codec, catch-up plan, row cursor):
    `protocol/chat2-vectors.json`. The Rust client, the Swift client and the
    edge server each run it (see `protocol/README.md`). Change a wire rule by
    changing the vector and every runner in the same PR. A new implementation,
    a Zig port for example, adds its own runner against the same file.
  - iOS and Android rules and copy: `apps/parity/` (see its README).
- **Performance bugs get a test of the shape**, not just the outcome: compare
  the slow path with the fixed one using a generous ratio. For example,
  `ConcurrentImportCostTests` asserts that a batched import is at least 5×
  faster than importing row by row.

### iOS tests

- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`: the
  selected developer directory may be the Command Line Tools.
- Boot the simulator, then `xcrun simctl bootstatus <udid> -b`. The first launch
  after a boot can fail with "No such process"; re-run with
  `test-without-building`.
- Run one `xcodebuild` per simulator at a time. Overlapping runs make the
  simulator kill the test host ("signal kill").
- UI tests that need the on-screen keyboard: shut the simulator down, run
  `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`,
  and delete the setting afterwards.
- UI tests that aren't about the phone split pass `-phoneSplit off`, because
  `PhoneSplitUITests`' "Try it" saves a split mode that later runs inherit.
- The iOS UI-test CI job is off, so verify iOS changes locally. `parity.yml`
  runs `ParityTests` and `Chat2VectorTests` in CI.
- Read results with `xcrun xcresulttool get test-results summary --path X.xcresult`.
  `xcrun xcresulttool export attachments` saves the failure screenshots.
- Device crash and hang reports from TestFlight builds are unsymbolicated, and
  the workflow doesn't keep dSYMs. Rebuild the same commit with the workflow's
  Xcode version and map the offsets with `atos`.

## Commits and pull requests

No Claude or Anthropic attribution anywhere: no `Co-Authored-By` trailers
naming Claude or Anthropic, no "Generated with Claude Code" footers, no
`claude.ai` / `claude.com` links, and no `noreply@anthropic.com` commit
identities, in commit messages, PR titles or bodies, or review comments.
Commits use the user's git identity as author; Codegraff / `blackfloofie`
co-author trailers (such as `Co-Authored-By: Codegraff <blackfloofie@codegraff.com>`)
are allowed. Turn off Claude Code's attribution setting when using it here.
Before pushing, check:

```bash
python3 scripts/check-attribution.py --range origin/main..HEAD
```

If a pushed commit fails the check, reword it and force-push the branch before
it is merged. Once it's on `main`, removing it means rewriting `main`.

### Every pull request shows before and after

A pull request's description has a **Before** screenshot and an **After**
screenshot of what it changes: an image under a `## Before` heading and one
under `## After`, or a two-column `| Before | After |` table. The template in
`.github/pull_request_template.md` has the sections. Screenshots go in the
description, not in a comment.

- Capture from made-up data, crop to what changed, and post with
  `scripts/issue-screenshot.sh <PR number> <images>` (see "Every issue carries
  an image" below for what must not be in them).
- For behaviour you can't see in one frame, show the before and after state
  (a dialog that now appears, a row that now opens), or a test's output
  rendered as an image when nothing is on screen at all.
- A pull request opened without both is **closed straight away** with the
  `needs-screenshots` label and a comment; editing the description to add
  them reopens it. The `PR screenshots` status check (required on `main` and
  `release/v*`) also fails until both are there. Both run
  `scripts/check-pr-screenshots.py`.
- A change with genuinely nothing to see, such as CI or a pure refactor, needs
  a maintainer to add the `no-screenshots` label (which also reopens it).
  Release pull requests (`release/...`) are exempt; their parts carry the
  screenshots. Pull requests opened before 2026-10-23 06:30 UTC aren't checked.

## Issue format: every report states its versions

This repository is public. Every issue, whether a person or an agent files
it, opens with this header. A report without versions can't be told apart
from a bug that a newer release already fixed.

```markdown
**Harness:** 0.2.109 (latest: 0.2.109)
**graff:** 0.0.302.25, the engine Harness runs
**App:** desktop | iOS 0.2.109 | Android 0.2.109
**Platform:** macOS arm64 | Windows x64 | Linux x64 | iOS 27 | Android 16 | ...

## Symptom
What went wrong, in generic terms, with the app's own error text verbatim.

## Repro
The smallest sequence of steps that shows it.

## Image
Required on every issue: a screenshot of what's wrong, or a picture of the
change you'd like (a mockup or an annotated screenshot). See below.

## Root cause
In code terms (`crate::module::function`), naming the tag or commit the
line numbers come from. Leave this section out if the cause isn't known.

## Fix
The expected behavior, or the proposed change.
```

- **Harness:** About Harness on macOS, or Settings → Devices. From a shell on
  macOS, run
  `plutil -extract CFBundleShortVersionString raw /Applications/Harness.app/Contents/Info.plist`.
  For the latest release, run `gh release view --repo justrach/harness --json tagName`.
- **graff:** Harness runs its managed copy, not the `graff` on `PATH`:
  `~/.harness/bin/graff --version` (macOS and Linux).
- **Engine bugs go to `justrach/codegraff`.** That covers tools, compaction,
  sessions, and model replies, and its issues use the same header.
- **If either version is older than the latest release**, check whether the
  release notes or a closed issue already cover the bug. Reproduce it on the
  latest release before filing, or say plainly in the header that it wasn't
  rechecked.
- **Search before filing.** Search open and closed issues by the error text.
  Comment on an existing issue only when you have a new repro or diagnostic.
- **What the header must not contain:** account details, private repository
  names, local paths, session ids, or transcript excerpts.

### Every issue carries an image

Every issue includes an image: for a bug, a screenshot that shows it; for a
change or feature, a picture of what you'd like changed, such as a mockup or
an annotated screenshot of where it goes. For a bug about how something looks
(layout, clipping, overlap, truncation, spacing, colors, rendering, a stuck or
wrong animation frame), the screenshot must show that. A pull request that
changes how something looks shows it before and after, at the sizes it was
checked at. A description of a picture can't be checked against the fix; a
screenshot can.

GitHub has no hook that runs before an issue is created, so this is enforced
right after:
- **Issue forms** (`.github/ISSUE_TEMPLATE`) require an Image field, and blank
  issues are off. `gh issue create --body` skips the forms; the workflow below
  still applies.
- **The `Issue image` workflow** (`scripts/check-issue-image.py`) runs on each
  new, edited or reopened issue. With no image, it labels the issue
  `needs-image`, comments, and closes it. Editing the issue to add one reopens
  it. With an image, it asks TypeSafe whether the first image shows what the
  issue describes (labelling `image-unclear` if not) and whether it shows
  private details; those two only warn.
- A maintainer who reopens an issue the check closed overrides it. Issues
  opened before 2026-10-23 aren't checked.

- **Capture from synthetic data, never the user's real app.** Run an isolated
  build (`scripts/run-macos-dev.sh`, or any build with its own
  `HARNESS_IPC_PORT` and `DATA_DIR`) or a fixture (for example
  `harness-ui --example browser-fixture`), with made-up chat titles,
  projects and prompts. On macOS, `screencapture -o -l <window id>` captures
  one window; on the iOS simulator, `xcrun simctl io booted screenshot`.
- **Crop to the part that's wrong**, and look at the image before posting.
  The same rules as the text apply: no real chat titles, prompts, file names,
  paths, account names, emails, device or host names, or other apps' windows.
- **Post it with** `scripts/issue-screenshot.sh <issue-or-pr-number> <image>...`.
  It uploads to the repository's `issue-media` branch and prints Markdown to
  paste into the issue, PR or comment. An uploaded image stays in that
  branch's history, so check it first.
- **Text rendering:** the GPUI fixtures in `crates/ui/examples` render synthetic
  content and save their own screenshots (for example `markdown-math-fixture`).
  Add a probe line that isolates the case (precomposed and combining forms side by
  side, for example) instead of reasoning from a description.
- **Showing a picture in a Harness chat:** save it inside the chat's folder and
  link it as `![caption](path)`, or call `show_image`. Harness only loads images
  from a chat's folder and its uploads, so a file elsewhere (under `/tmp`, say)
  shows only its caption.
- **If it can only be seen with real data**, don't post that capture.
  Recreate it with made-up data, or attach a mockup of what it looks like, and
  say in the issue why the real capture isn't attached.

### TypeSafe image requests

Requests to TypeSafe's System One API (`POST https://api.typesafe.ai/v1/systemone`)
that carry an image or a Box question send the header
`TypeSafe-Danger-Zone-Images: true`; without it the API answers `400`. Images
are PNG or JPEG, 280 to 1568 px a side and at most 16 MiB each, and aren't
resized for you. The key is the `TYPESAFE_API_KEY` Actions secret; never write
it into a file, log or issue.

## Heavy builds

One compile at a time; watch `ps -o rss=` on long builds and stop anything
growing past ~40 GB. Never use Zig's self-hosted backend for large builds
(system-level rule, applies to zigrepper/codedb work in this tree).

When several agents work in parallel worktrees on one machine, wrap every
`cargo`, `xcodebuild` and `zig build` in `scripts/heavy-build.sh <command>`,
which runs them one at a time across processes. Each worktree builds into its
own `CARGO_TARGET_DIR`. A shared target directory reuses crates built from
another checkout's sources.

## Imported conversations continue in graff

A conversation brought in from another agent (Claude Code, Codex, or any other)
continues in a graff session, on graff's configured provider (for example
Codegraff). The source agent's transcript is read-only input. Never re-launch or
`--resume` the source agent to continue it, and never spend that agent's
subscription or credits. "Import & resume" and "Continue in graff" both mean a
new graff session seeded with the imported conversation (#168).
