# Parity between the iOS and Android apps

The SwiftUI app is the reference. Rules and copy that must read the same on both phones live here as data, and
each app runs its own test against the same files, so neither can drift without a test failing on one side.

| File | What it pins | iOS runs it in | Android runs it in |
| --- | --- | --- | --- |
| `vectors/message-queue.json` | queue labels, one-line text, moves, host-action results, edit leases | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/account-deletion.json` | every answer the edge can give and the exact message shown | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/home-grouping.json` | project and device sections, the Pinned section | `ParityTests.swift` | `ParityTest.kt` |
| `ux-contract.json` | user-visible strings and the queue panel's layout numbers | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/agent-readiness.json` | when an agent counts as brought in (Graff, Claude Code, OpenAI Codex on an online computer), and the download link | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/run-errors.json` | which run errors read as signed out or limit reached, and their labels (the desktop checks it too, in `harness-proto`'s `run_errors`) | `ParityTests.swift` | not yet |
| `vectors/registry-projection.json` | which registry rows become devices, projects, sessions and pins, with their defaults and order | `ParityTests.swift` (through `WorkspaceStore`) | `ParityTest.kt` (through the native core, `crates/mobile`) |
| `vectors/transcript-decode.json` | how a session doc's messages, parts and queue rows decode, and which ones are dropped | `ParityTests.swift` (through `SessionStore`) | `ParityTest.kt` (through the native core) |
| `vectors/cloud-sandbox.json` | how a cloud sandbox list reads: row titles, details and buttons, hourly rates, size choices, the running summary, and which size a create names (the desktop checks it too, in `harness-ui`'s `codegraff_sandboxes`; its gateway half, from sign-in and call plans to error sentences, runs in the engine, which the phone reaches through one of its computers) | `ParityTests.swift` | not yet |
| `vectors/chat-mode.json` | chat mode's auto tiers (order, names, the older-gateway stand-in), when a chat can start, the model a new chat starts on, and the cost and unavailable notes (the desktop checks the same rules in `harness-ui`'s `chat_mode`) | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/composer-stop.json` | how long the composer ignores Stop after a question panel gives way to it (the desktop checks it too, in `harness-ui`'s `composer`) | `ParityTests.swift` | `ParityTest.kt` |
| `perf-contract.json` | the operations the performance monitor times, their budgets, and the Performance page copy | `ParityTests.swift` | `ParityTest.kt` |
| `apps/ios/Harness/Theme/themes.json` | the theme catalog (Android bundles a copy) | `ThemeStoreTests.swift` | `ThemeCatalogTest.kt` |

The expected values are what the SwiftUI app does. Change a rule on iOS and the vector must change with it, which
then fails the Android test until the port follows, and the other way round.

## Adding a rule

1. Add cases to a file in `vectors/`, working out the expected value from the iOS behavior.
2. Add the check to `ParityTests.swift` and run it: `xcodebuild test -only-testing:HarnessTests/ParityTests`.
3. Add the same check to `ParityTest.kt` and run it: `./gradlew :app:testDebugUnitTest --tests '*ParityTest'`.

Both halves run in CI: `parity.yml` runs the Swift tests on a macOS runner (the full iOS unit suite is switched
off in `ui-tests.yml`, so it gets its own job) and `android.yml` runs the Kotlin tests.

A new piece of user-visible copy goes in `ux-contract.json`. Each test checks that the string appears as a quoted
literal in its own source tree, which catches a reworded label or a copy that was never ported.

## What this does not cover

It checks rules, copy and a few layout numbers. It does not compare pixels, animation, or how a screen feels, so
visual parity still needs eyes on both apps. It also assumes a rule is reachable as a pure function or a model
call: behavior that only exists inside a view has to be pulled out before it can be pinned here.

Known differences that are not pinned: the queue panel shows an image placeholder where iOS decodes the upload, and
Android's drafts survive navigation but not the process being killed, while iOS keeps them on disk.

The Attachments editor on a queued message (add, preview, replace and remove its images; #187, #493) is iOS-only
for now. Its copy goes into `ux-contract.json` when the Compose app gets the editor, since the string check would
otherwise fail the Android build.
