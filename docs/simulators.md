# Simulators

Settings → Simulators on the phone lists the iOS Simulators on one of your
Macs. Open one to watch its screen live and use it from the phone: touches,
swipes, typed text, and the Home, Lock, and volume buttons go to the simulator.
A simulator that is off starts when you open it; swipe a running one to shut it
down.

## Setting up

Streaming needs a helper on the Mac. Nothing is installed until you tap **Set
up** on the phone: the Mac's engine then npm-installs a pinned
`expo-device-hub` into `<data dir>/tools` (Node.js 20 or newer must be on the
Mac). The helper only listens on loopback and is started by the engine when a
viewer opens; it stops with the engine. Simulators themselves are never shut
down unless you ask.

## How it works

The engine owns every route to the helper, so a phone never reaches it
directly:

- `ListSimulators`, `BootSimulator`, and `ShutdownSimulator` use
  `xcrun simctl`. Simulator ids must be CoreSimulator UDIDs.
- `WatchSimulatorScreen` reads the helper's MJPEG stream (downscaled on the
  Mac) and re-emits each frame as a stream item. One pump per simulator is
  shared by every viewer, the latest frame wins (a slow viewer skips frames
  instead of queueing them), and the pump stops when the last viewer leaves.
- `SimulatorInput` takes typed input and translates it into the helper's HID
  socket messages: touches as fractions of the screen, hardware buttons, text
  as US-keyboard key presses, and named keys (enter, backspace, arrows). The
  helper's shell-exec and dashboard routes are never exposed.

All of these are relay-forwardable, so they reach the Mac from any signed-in
device. `SetUpSimulators` and `BootSimulator` get long relay deadlines.

## Limits

- iOS Simulators on macOS only. Android emulators are not wired yet.
- Text input is US-keyboard ASCII; other characters are refused by name.
- Frames are JPEG over the relay; there is no video codec yet.
