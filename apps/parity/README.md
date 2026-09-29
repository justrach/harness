# Parity between the iOS and Android apps

The SwiftUI app is the reference. Rules and copy that must read the same on both phones live here as data, and
each app runs its own test against the same files, so neither can drift without a test failing on one side.

| File | What it pins | iOS runs it in | Android runs it in |
| --- | --- | --- | --- |
| `vectors/message-queue.json` | queue labels, one-line text, moves, host-action results, edit leases | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/account-deletion.json` | every answer the edge can give and the exact message shown | `ParityTests.swift` | `ParityTest.kt` |
| `vectors/home-grouping.json` | project and device sections, the Pinned section | `ParityTests.swift` | `ParityTest.kt` |
| `ux-contract.json` | user-visible strings and the queue panel's layout numbers | `ParityTests.swift` | `ParityTest.kt` |
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
