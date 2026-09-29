# Harness for Android

A native Kotlin and Jetpack Compose viewport onto the Harness sync mesh, the Android counterpart of
[`apps/ios`](../ios). Like the phone app on iOS, it is a **peer device**: no engine runs on the
handset. Agents run on your desktop hosts and the phone renders their sessions and drives them.

## Status

The UI is a port of the SwiftUI app, screen for screen, running on the offline **demo dataset** (the
same fixtures as the iOS `-demo` mode). Live sync is not wired yet.

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

1. Loro CRDT client (the engine uses loro 1.13; the iOS app uses `loro-swift`, an UniFFI binding of
   `loro-ffi`, which can also generate Kotlin bindings).
2. Registry and chat-room sockets to the edge, mirroring `apps/ios/Harness/Sync`.
3. CodeGraff sign-in (PKCE, `harness://callback`) and the durable command queue.
4. Real attachment upload, the queued-message panel, notifications, launcher icon, Live Activity analogue.

The streaming "veil" fade on live text is not ported; new text appears at once.

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

Requires JDK 17+ (Android Studio's bundled JDK works) and the Android SDK (platform 35). Point Gradle at
the SDK with `local.properties` (`sdk.dir=/path/to/Android/sdk`) or `ANDROID_HOME`.

```sh
cd apps/android
./gradlew :app:testDebugUnitTest          # 49 unit tests
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
| `AppModel.kt` | `AppState` driven by the dataset; the sync client will sit behind the same state |
| `theme/` | Theme catalog and store, palette and tokens, fonts, brand marks, line icons and glyphs, motion |
| `ui/components/` | Glass, loaders, status indicators, sheet chrome, PR badge |
| `ui/home/`, `ui/session/`, `ui/newsession/`, `ui/settings/`, `ui/sheets/`, `ui/signin/` | The screens |
