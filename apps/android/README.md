# Harness for Android

A native Kotlin and Jetpack Compose viewport onto the Harness sync mesh, the
Android counterpart of [`apps/ios`](../ios). Like the phone app on iOS, it is a
**peer device**: no engine runs on the handset. Agents run on your desktop
hosts and the phone renders their sessions and drives them.

## Status

Early scaffold. It runs the offline **demo dataset** only (the same starting
point as the iOS `-demo` mode):

- Sessions list grouped by recency, status dots, archived shelf.
- Session view with user bubbles, assistant text, collapsible tool groups
  (failed calls in the danger color) and a keyboard-aware composer.
- Sending a message streams a scripted reply into a live row.
- Light and dark, painted from the same theme registry as desktop and iOS
  (`theme/Palette.kt` is generated from `apps/ios/Harness/Theme/themes.json`).

Not built yet, in the order they are needed for a real connection:

1. Loro CRDT client (the engine uses loro 1.13; the iOS app uses `loro-swift`,
   an UniFFI binding of `loro-ffi`, which can also generate Kotlin bindings).
2. Registry and chat-room sockets to the edge, mirroring
   `apps/ios/Harness/Sync`.
3. CodeGraff sign-in (PKCE, `harness://callback`) and the durable command queue.
4. Markdown rendering, attachments, launcher icon, notifications.

## Build and run

Requires JDK 17+ (Android Studio's bundled JDK works) and the Android SDK
(platform 35). Point Gradle at the SDK with `local.properties`
(`sdk.dir=/path/to/Android/sdk`) or `ANDROID_HOME`.

```sh
cd apps/android
./gradlew :app:testDebugUnitTest      # unit tests
./gradlew :app:assembleDebug          # app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n harness.codegraff.android/.MainActivity
```

Or open `apps/android` in Android Studio and run the `app` configuration.

## Layout

| Path | What |
| --- | --- |
| `model/` | Kotlin mirrors of the workspace and session rows (`Entities.kt`, `Transcript.kt`) |
| `demo/` | Offline dataset and the scripted streaming reply |
| `AppModel.kt` | Screen state (`AppState`) driven by the dataset; the sync client will sit behind the same state |
| `theme/` | Paint and layout tokens, Geist fonts |
| `ui/` | Home, session and composer screens |
