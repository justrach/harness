# Harness for Android

A native Kotlin and Jetpack Compose viewport onto the Harness sync mesh, the Android counterpart of
[`apps/ios`](../ios). Like the phone app on iOS, it is a **peer device**: no engine runs on the
handset. Agents run on your desktop hosts and the phone renders their sessions and drives them.

## Status

The UI is a port of the SwiftUI app, screen for screen. It runs either on the offline **demo dataset** (the
same fixtures as the iOS `-demo` mode) or on **live sync** with an edge through the native core (see
[Live sync](#live-sync)). **Log in to Harness** signs in with CodeGraff (PKCE in the browser, back through
`harness://callback`, as on iOS) and opens live sync; **Explore the demo** opens the demo. Debug builds also
take a launch rig against a dev edge.

| Screen | What is ported |
| --- | --- |
| **Home** | Space dropdown, plus and person capsule, status chips with counts, Group by project or device with collapsible sections, swipe to archive and pin, archived shelf with paging, search, the session switcher pill and its sheet, PR badges, working spinner |
| **Session** | Floating back button and `project @ device` header, transcript rows (user bubble with collapse, markdown blocks, tables, quotes, code with highlighting, tool groups with the activity rail, error and question chips), status strip with the sunrise spinner and flavour words, jump to latest |
| **Composer** | The glass shell that morphs from capsule to card, attach photos, PR / branch / model / effort / option chips, model picker (sections per provider with logos), Traits picker, option picker, stop and queue, question wizard |
| **New session** | "What are we building?" canvas, checkout and ref pickers, host picker for sessions without a project, sticky harness and model |
| **Settings** | Account, Appearance (all 19 theme families, Light / Dark variants, Match desktop, System / Light / Dark, live preview card), About |
| **Other** | Space page, new-space folder browser, sign-in gate |

Provider logos (Claude, OpenAI, Cursor, Devin, Grok, Hermes, Pi, OpenCode, Antigravity) are the
desktop's exact SVG path data, generated into `theme/BrandMarkPaths.kt`. Themes come from
`themes.json`, the same registry desktop and iOS install (a unit test fails if the bundled copy drifts).

Not built yet, in the order they are needed for a real connection:

1. Connectivity states on screen (offline, reconnecting), presence by iOS's rule, and the device relay
   (folders, agents, models, refs, change requests).
2. A "Sending…" state for a message the computer has not picked up yet. Sending, queueing, stopping and
   answering questions are built (see Live sync), as is CodeGraff sign-in (`auth/`): the tokens are sealed
   with an Android Keystore key and refreshed by iOS's rules.
3. Real attachment upload (live sessions hide the photo button until then), notifications, launcher icon,
   Live Activity analogue.

## Staying in step with iOS

`apps/parity` holds the rules and copy both apps must share as JSON, and each app tests against it (see
`apps/parity/README.md`). `ParityTest` covers the message queue, account deletion, the Home grouping and the UX
contract. CI (`.github/workflows/android.yml`) runs those with lint and the debug build, builds the minified release
bundle and the perf APK, and runs the instrumented tests on an emulator. `android-release.yml` builds a bundle to
download from a run; nothing publishes to the Play Store.

## Live sync

The sync protocol is the desktop's own Rust code (`crates/doc`, `crates/sync`), wrapped for the phone by
`crates/mobile` and called through generated UniFFI bindings. The core:

- mirrors the **workspace registry**: the on-device copy loads before anything dials, then
  `harness_sync::RegistryClient` keeps it converged over the socket, with plain HTTPS beside it (a first
  pull in one round trip, and sync on networks that strip socket upgrades). The rows are projected the
  way the iOS `WorkspaceStore` projects them, and the phone writes only what iOS writes (chat creates,
  archive, rename, seen marks, chat config, pins, project folders);
- mirrors each open **session doc** (Loro): hydrated from disk, joined to its chat2 room once the registry
  says the chat is on room generation 2, saved together with its room cursor, and decoded into the
  transcript and queue the way `SessionStore` decodes them;
- writes to a session doc the way iOS does: run, steer, interrupt and answer commands, and queue rows
  (add, move, remove after the computer confirms). Each edit is journaled in the chat's outbox before it is
  sent and leaves it when the room acknowledges it, so a send made offline goes out on reconnect, even after
  the app is killed. The queue's actions and edit leases are requests to the computer over the device relay;
- publishes snapshots to `sync/LiveSync.kt`, which maps them onto the same `AppState` flows the demo
  drives, so the screens do not know which one they are showing.

`apps/parity/vectors/registry-projection.json` and `transcript-decode.json` pin the projection and the
decoding against iOS.

To try it, run the edge in dev auth mode, publish a stand-in host, and launch a debug build at it:

```sh
(cd edge && npm run dev)                                    # AUTH_MODE=dev edge on :27640
cargo run -p harness-mobile --example dev_host -- http://127.0.0.1:27640 u1 org1
adb shell am start -n harness.codegraff.android/.MainActivity \
    --es edge http://10.0.2.2:27640 --es user u1 --es org org1
```

The extras are read only by debuggable builds (the iOS counterparts are the `-setedge`, `-setmode dev`,
`-setuser` and `-setorg` launch arguments). `HARNESS_TEST_EDGE=http://127.0.0.1:27640 cargo test -p
harness-mobile --test live_edge -- --ignored` runs the same round trip without a device.

## Responsiveness

The same design the iOS app uses to stay smooth on long, streaming sessions:

- **Narrow observation.** `AppModel` publishes the workspace (sessions, devices, pins, PRs) and each chat's
  transcript as separate flows. A streamed token replaces only that chat's entry list, so Home, the
  switcher and every other row do not recompose (`AppModelTest.aStreamedTokenNeverRepublishesTheWorkspace`).
- **Row cache.** `TranscriptBuilderCache` parses each markdown part once; a token re-parses only the live
  tail, and rows that did not change keep their identity so the lazy list skips them (`ResponsivenessTest`).
- **Stable model types** (`compose-stability.conf`) so Compose skips by equality, plus `remember`ed
  filtering, grouping, counting and syntax highlighting, and `contentType` on every list.
- **Streaming veil.** Appended text fades in through a paint-only alpha (`ui/session/Veil.kt`, a port of
  `Veil.swift`); a frame loop runs only while a chunk is fading.
- **Cheap scrolling rows.** Row backgrounds and press washes are drawn, not recomposed or clipped per
  row; the tool rail and quote bar are painted behind the row instead of using `IntrinsicSize` (which
  measures each row twice); only collapsible bubbles animate their size.
- **Baseline profile** (`app/src/main/baseline-prof.txt`) covers the app plus the Compose runtime, UI,
  foundation and animation code, so the first swipe after install is not interpreted. A profile generated
  by a Macrobenchmark run should replace it once that module exists.
- The reply list is reversed, so the bottom stays anchored with no per-token scroll call, and a slow
  15 s clock (not every write) moves relative times forward.

Measure on the `perf` build, on a device. A debug build is several times slower in Compose, and an
emulator on a busy host says little.

## Design language

The look is the SwiftUI app's: floating glass controls, capsule chips, hairline-separated sheets,
tracked uppercase labels, muted brand marks. It sits on Material 3 foundations: `MaterialTheme` with
every color role mapped from the Harness palette (`HarnessPalette.toColorScheme()`), the M3 type scale
in Geist, `ModalBottomSheet`, `DropdownMenu`, `SwipeToDismissBox` and `Switch`, 48dp touch targets,
content descriptions, edge-to-edge insets and predictive back.

- **Fonts:** [Geist](https://github.com/vercel/geist-font) for text and
  [Google Sans Code](https://github.com/googlefonts/googlesans-code) for code (inline code, code
  blocks, tool details). Both are SIL OFL; notices are in `third_party/licenses/`.
- **Glass:** Android has no system glass material, so a glass surface is the palette's shell color at
  high opacity with a faint ink wash, a hairline edge and a soft shadow (`ui/components/Glass.kt`).
- **`Color.opacity()`:** SwiftUI's `.opacity(x)` multiplies a color's alpha; Compose's
  `copy(alpha = x)` replaces it, which is wrong for the theme's translucent borders. Use
  `opacity()` for anything ported from SwiftUI.

## Foldables and large screens

At 600dp wide and up Home becomes a sidebar next to the open page (the iPad split layout); below that it
is one stack. When a vertical hinge splits the screen the sidebar ends at the fold. Folding and unfolding
recreates the activity, and the open route, filters, drafts and disclosure state are saved across it.
Handling size changes in place instead left a stale two-pane layout on the cover screen, so the manifest
does not declare `screenSize`. Tested on a Pixel Fold emulator (closed and open).

## Build, run, test

Requires JDK 17+ (Android Studio's bundled JDK works) and the Android SDK (platform 35) with NDK
27.1.12297006. Point Gradle at the SDK with `local.properties` (`sdk.dir=/path/to/Android/sdk`) or
`ANDROID_HOME`.

The sync protocol is Rust, shared with the desktop: `crates/mobile` wraps `crates/doc` and `crates/sync`
for the phone and is exposed to Kotlin with [UniFFI](https://mozilla.github.io/uniffi-rs/) over JNA. Gradle
builds it, so you also need the Rust toolchain from `rust-toolchain.toml` with the Android targets:

```sh
rustup target add aarch64-linux-android x86_64-linux-android
```

- `cargoBuildHost` builds the core for your machine; the JVM unit tests load it, and
  `generateUniffiBindings` reads the Kotlin bindings out of it (into `app/build/generated/uniffi`).
- `cargoBuildArm64V8a` and `cargoBuildX8664` build it per ABI in the `mobile` cargo profile, linked with the
  NDK's clang, into the APK's `jniLibs`. Only packaging runs them, so a unit-test run never cross-compiles.
  `-Pharness.abis=x86_64` limits the ABIs; the APK ships only the ones built (no 32-bit).

```sh
cd apps/android
./gradlew :app:testDebugUnitTest          # unit tests, including the iOS/Android parity tests
ANDROID_SERIAL=<device> ./gradlew :app:connectedDebugAndroidTest   # 6 UI tests on one device
./gradlew :app:assembleDebug              # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assemblePerf               # minified, debug-signed: measure performance with this
```

Set `ANDROID_SERIAL` when more than one device or emulator is attached; the UI tests otherwise run on all
of them. A debug build is several times slower in Compose than a release build, and emulator frame times
say little about a phone: use the `perf` variant on a device. `src/main/baseline-prof.txt` is a coarse
hand-written baseline profile (installed by `profileinstaller`).

Foldable emulator: create an AVD from the `pixel_fold` profile, then
`adb shell cmd device_state state 0|2|reset` (closed, open) and, with several displays,
`adb exec-out screencap -d <display-id> -p`.

## Layout

| Path | What |
| --- | --- |
| `model/` | Entities, indicators and ordering, transcript rows, markdown reader, harness and model catalogs, Home filter and grouping |
| `demo/` | The offline dataset and the scripted streaming reply |
| `AppModel.kt` | `AppState`, driven by the demo dataset or by live sync behind the same flows |
| `sync/` | The live sync wrapper around the native core, and the mapping onto the model types |
| `../../crates/mobile` | The native core (Rust); its Kotlin bindings are generated into `harness.codegraff.android.core` |
| `theme/` | Theme catalog and store, palette and tokens, fonts, brand marks, line icons and glyphs, motion |
| `ui/components/` | Glass, loaders, status indicators, sheet chrome, PR badge |
| `ui/home/`, `ui/session/`, `ui/newsession/`, `ui/settings/`, `ui/sheets/`, `ui/signin/` | The screens |
