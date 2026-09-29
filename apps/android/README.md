# Harness for Android

A native Kotlin and Jetpack Compose viewport onto the Harness sync mesh, the
Android counterpart of [`apps/ios`](../ios). Like the phone app on iOS, it is a
**peer device**: no engine runs on the handset. Agents run on your desktop
hosts and the phone renders their sessions and drives them.

## Status

Early. It runs the offline **demo dataset** (the same starting point as the iOS
`-demo` mode):

- **Home:** large collapsing top bar, *All / Needs you / Running* filter chips
  with counts, M3 list items with status dots and relative age, an archived shelf.
  Unread sessions are set in a heavier weight.
- **Session:** top app bar with device and branch, user bubbles, markdown
  assistant text (headings, lists, `code`, **bold**, fenced blocks), collapsible
  tool groups with failed calls in the error color, and a keyboard-aware composer.
- Sending a message streams a scripted reply into a live row.
- Light and dark, painted from the same theme registry as desktop and iOS
  (`theme/Palette.kt` is generated from `apps/ios/Harness/Theme/themes.json`).

Not built yet, in the order they are needed for a real connection:

1. Loro CRDT client (the engine uses loro 1.13; the iOS app uses `loro-swift`,
   an UniFFI binding of `loro-ffi`, which can also generate Kotlin bindings).
2. Registry and chat-room sockets to the edge, mirroring
   `apps/ios/Harness/Sync`.
3. CodeGraff sign-in (PKCE, `harness://callback`) and the durable command queue.
4. New session, attachments, notifications, launcher icon, appearance setting.

## Material Design 3

- Stock M3 components throughout: `LargeTopAppBar`, `TopAppBar`, `ListItem`,
  `FilterChip`, `TextField`, `FilledIconButton`, `Scaffold`.
- Every color role is mapped from the Harness palette
  (`HarnessPalette.toColorScheme()`), so components paint correctly with no
  per-component overrides. The type scale is M3's, set in Geist.
- Touch targets are at least 48dp; icon buttons carry content descriptions; each
  list row announces title, device, status and age as one item.
- Edge-to-edge with insets handled per pane; predictive back is enabled.

## Foldables and large screens

The layout is the canonical M3 **list-detail** scaffold
(`NavigableListDetailPaneScaffold`):

| Window | Layout |
| --- | --- |
| Compact (phone, folded cover screen) | One pane. Opening a session pushes it, with a back arrow. |
| Medium (600dp+, portrait tablet, half-open) | One pane, same as compact. |
| Expanded (840dp+, unfolded foldable, landscape tablet) | Sessions list and the open session side by side; the open row is highlighted. |

- The scaffold keeps panes clear of a hinge that splits the screen.
- The transcript and composer cap at 720dp so lines stay readable when unfolded.
- Folding and unfolding recreates the activity. The open session, list filter,
  tool-group disclosure and unsent draft are saved across it
  (`rememberSaveable` and the saveable navigator), and the demo state lives in a
  `ViewModel`. Handling size changes in place instead left a stale two-pane
  layout on the cover screen, so the manifest does not declare `screenSize`.
- **Tabletop** (half-open with a horizontal fold): when the window reports a
  separating horizontal hinge, the transcript is bounded to the top half so no
  text crosses the fold, and the composer stays in the bottom half within reach
  (`ui/Posture.kt`). The geometry is unit-tested, but the emulator does not
  report a hinge to Jetpack WindowManager, so this path has not been seen
  running. Check it on a device.

## Build, run, test

Requires JDK 17+ (Android Studio's bundled JDK works) and the Android SDK
(platform 35). Point Gradle at the SDK with `local.properties`
(`sdk.dir=/path/to/Android/sdk`) or `ANDROID_HOME`.

```sh
cd apps/android
./gradlew :app:testDebugUnitTest          # 20 unit tests
./gradlew :app:connectedDebugAndroidTest  # 4 UI tests on a running device or emulator
./gradlew :app:assembleDebug              # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assemblePerf               # minified, debug-signed: measure performance with this
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n harness.codegraff.android/.MainActivity
```

A debug build is several times slower in Compose than a release build, and
emulator frame times say little about a phone. Use the `perf` variant on a
device. `src/main/baseline-prof.txt` is a coarse hand-written baseline profile
(installed by `profileinstaller`); replace it with a generated one when a
Macrobenchmark module exists.

To try foldables: create an AVD from the `pixel_fold` or `pixel_9_pro_fold`
profile, then `adb shell cmd device_state state 0|1|2` (closed, half-open, open)
and `adb shell cmd device_state state reset`. With several displays,
`adb exec-out screencap -d <display-id> -p`.

The streaming reply scrolls with a reversed list (newest row at index 0), so the
bottom stays anchored while the reply grows and no scroll call runs per token.

## Layout

| Path | What |
| --- | --- |
| `model/` | Rows and derivations (`Entities.kt`, `Transcript.kt`), markdown reader (`Markdown.kt`) |
| `demo/` | Offline dataset and the scripted streaming reply |
| `AppModel.kt` | `AppState` driven by the dataset; the sync client will sit behind the same state |
| `theme/` | Palette, M3 color scheme and type scale, Geist fonts |
| `ui/` | `HarnessApp` (adaptive scaffold), `HomePane`, `SessionPane`, `Composer`, `MarkdownText`, `Posture` |
