# Simulators

Settings → Simulators on the phone lists the iOS Simulators on one of your
Macs. Open one to watch its screen live and use it from the phone: touches,
swipes, typed text, and the Home, Lock, and volume buttons go to the simulator.
A simulator that is off starts when you open it; swipe a running one to shut it
down. The row only appears when one of your computers is a Mac.

## Setting up

Streaming needs a helper on the Mac. Nothing is installed until you tap **Set
up** on the phone: the Mac's engine then installs a pinned `expo-device-hub`
into `<data dir>/tools` with the Mac's own npm (Node.js 20 or newer).

- **Pinned exactly.** The engine ships `package.json` and `package-lock.json`
  (`crates/engine/src/simulators/helper/`). The install is `npm ci
  --ignore-scripts`, so every package's version and sha512 integrity come from
  that lockfile and no package's install script runs. A changed lockfile is a
  new install.
- **Staged.** npm runs in a staging directory next to the install. The engine
  checks the helper's own version and files, writes a sentinel naming the
  version and the lockfile's hash, and only then renames it into place.
- **Clear failures.** A missing or old Node.js, a timeout, or npm's own error
  comes back to the phone as a sentence; npm's full output is in
  `<data dir>/tools/simulator-setup.log`.

## How it runs

The engine starts the helper on first use through its own host script
(`helper/harness-sim-host.mjs`), not the helper's dashboard server:

- It binds `127.0.0.1` on a port it picks and serves only two routes: one
  simulator's MJPEG stream and its HID socket. The helper's shell-exec,
  dashboard, devtools, and device-management routes are refused.
- Both routes need a bearer token minted for each run and passed to the host
  in its environment, so other processes on the Mac can't drive a simulator
  through it. The engine's own requests skip any proxy.
- It runs in its own process group and exits when its stdin closes, which
  happens when the engine stops or is killed. Its pid and start time go in
  `<data dir>/tools/simulator-hub.pid`; the next start stops a leftover host
  only when that pid still has the recorded start time and runs this
  install's host script, so a reused pid is never signalled.
- With nobody watching for a minute it stops. Simulators themselves are never
  shut down unless you ask.

## Calls

- `ListSimulators`, `BootSimulator`, and `ShutdownSimulator` use
  `/usr/bin/xcrun simctl`. An id must be the UDID of an iOS Simulator `simctl`
  lists at that moment; nothing else reaches a URL or a command line. When
  `xcode-select` points at the Command Line Tools, the engine uses
  `/Applications/Xcode.app` if it's there.
- `WatchSimulatorScreen {simulatorId, maxFps?}` reads the helper's MJPEG
  stream and re-emits each frame (`{seq, jpeg}`, base64). One pump per
  simulator is shared by every viewer and stops with the last one. The latest
  frame wins: a slow viewer skips frames instead of queueing them.
- `SimulatorInput {simulatorId, input}` takes typed input and translates it
  into the helper's HID socket messages: touches as fractions of the screen,
  hardware buttons, text as US-keyboard key presses (at most 500 characters a
  call), and named keys (enter, backspace, escape, tab, arrows).
- `SetUpSimulators` is the install above.

All six are device-addressed like terminals: the phone sends them over the
Mac's relay room, which only the account's own devices can open, and the
engine also serves them on its loopback IPC port. `SetUpSimulators` and
`BootSimulator` get long relay deadlines. Off macOS, `ListSimulators` answers
unsupported and the rest refuse.

## Bandwidth

Frames are made at most 960 px on the long side, JPEG quality 0.6, and 20 a
second on the Mac. Each viewer then gets at most its own rate: the phone asks
for 15 a second, or 6 on a metered (cellular) or Low Data Mode network.

## Testing

- Engine: `cargo test -p harness-engine --lib simulators`.
- iOS: `SimulatorsTests` and `SimulatorsUITests` (demo mode serves a made-up
  Mac with `-demo`, `-simulators-set-up` skips setup).
- End to end, debug builds: run a headless engine with its own
  `HARNESS_IPC_PORT`, `HARNESS_DATA_DIR`, and `HOME`, and
  `HARNESS_SIMULATOR_ALLOWLIST=<udid,...>` naming only simulators the run
  created, so nothing else can be booted, shut down, or driven. Launch the app
  with `-demo -simulator-engine <port>` to send the Simulators screens to that
  engine's loopback port. `SimulatorsUITests.testLiveSimulatorThroughARealEngine`
  does this when given `TEST_RUNNER_HARNESS_SIM_ENGINE_PORT` and
  `TEST_RUNNER_HARNESS_SIM_UDID`.

## Limits

- iOS Simulators on macOS only. Android emulators are not wired yet.
- Text input is US-keyboard ASCII; other characters are refused by name.
- Frames are JPEG over the relay; there is no video codec yet.
- The helper is pre-1.0 and changes quickly upstream; the host script uses its
  bundled serve-sim middleware directly, so moving the pin means re-checking
  that the middleware's options and routes still match.
