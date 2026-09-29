# Performance monitor

Both apps time themselves on the device and show the result under Settings > Performance. Nothing is uploaded, and
"Copy report" produces plain numbers (no chat content, names or identifiers) to paste into an issue.

| | iOS (`PerfMonitor.swift`) | Android (`perf/Perf.kt`) |
| --- | --- | --- |
| Operations against budgets | `Perf.measure`, also signpost intervals for Instruments | `Perf.measure`, also `Trace` sections for Perfetto |
| Frame health | main run loop turn length: slow over 16.7 ms, frozen over 700 ms | `FrameMetrics` per frame against the system's own deadline, with the stage that took longest |
| Main-thread stalls | any turn of 50 ms or more, recorded as `main.stall` | a 100 ms timer that fires late, recorded as `main.stall` |
| Startup | process start to first screen | process start to first draw |
| Device | memory footprint, thermal state, Low Power Mode | Java and native heap, collections, thermal status, Battery Saver |

The operations and budgets are pinned in `perf-contract.json`: `startup.firstFrame`, `nav.open` (tap to the page it
opened), `transcript.rows`, `markdown.parse`, `home.group`, `send.apply`, `main.stall`. An operation over budget is
shown in red and logged (`HarnessPerf` on Android, the `perf` category on iOS).

Reading it: if slow frames blame layout, look at measure and layout work; if they blame the GPU or display, the cost
is in what is drawn or the device, not in Kotlin or Swift code. A stall with no slow operation beside it is work the
monitor does not name yet, so add a span there.

## Sharing anonymous reports

On by default, with a "Share anonymous performance data" switch in Settings to turn it off, and only active once a
destination is configured (`PerfSharing.endpoint` on each app, unset until the backend is agreed; with no endpoint the
switch is hidden and nothing is built or sent). While it is on, the app sends one report as it goes to the background.
A person who has turned it off stays off: only a never-chosen setting reads as on.

- **Content:** `vectors/perf-report.json` pins the JSON both apps produce: app, OS and device model (the hardware
  identifier, never the name the owner gave it, capped at 40 characters), refresh rate, startup, frame or turn counts,
  memory, thermal state, and the fixed operation names above. Any other name is dropped before it is sent.
- **Identity:** a random id per launch, so one launch's reports can be joined but never linked to a person or to the
  next launch. No account, install, device or session identifier, and no chat content.
- **Rules:** an endpoint exists, sharing is on, the session drew at least 60 frames or turns, at most one report per
  10 minutes, and a failed post does not start the wait. Both apps test these against the same vectors.
- **Transport:** a JSON POST over https (loopback http for tests), with no cookies, credentials, cache or redirects.
- **Store listings and disclosure:** collecting on by default means declaring diagnostics (performance data, not linked
  to the user) in the App Store privacy answers and the Play data safety form, and saying so in the privacy policy
  before an endpoint is switched on.

## What the server answers

Reports go to `POST /v1/telemetry/perf` as `application/json`, unauthenticated (the report carries no account and an
app-embedded key would only look like protection). The server validates strictly and stores no address.

| Status | Meaning | The app |
| --- | --- | --- |
| 204 | stored, or accepted and dropped by a daily cap | counts as sent |
| 429 | rate limited | starts the 10 minute wait |
| other 4xx | for example a route not deployed yet | starts the wait |
| 400, 413, 415 | the report is invalid, over 4 KB, or not JSON | stops sending for the rest of the launch |
| 5xx, no connection | server or network trouble | no wait; tried again at the next chance |

To stay inside what the server accepts, the report builder makes values fit rather than sending something that would
be refused for good: milliseconds are capped at 60000, frame totals stay under 10 million with slow and frozen no larger
than the total, the refresh rate stays within 24 to 240 Hz, and the device model keeps only letters, digits and
` ,._()-`. `vectors/perf-report.json` pins all of it. Raw reports are kept for 90 days, with daily roll-ups after that.
Nothing identifies a person, so there is no per-person deletion; the privacy text should say so.

## What it costs the device

The monitor must not be what slows the app or drains the phone, so its cost is bounded and was measured.

- **Per call:** recording an operation takes about 0.05 µs on Android and tallying a frame about 0.03 µs (a unit test
  fails above 5 µs; the iOS test fails above 25 µs in a debug build, to catch a hundredfold regression).
- **Frames:** the frame listener runs on its own thread and only while the app is in front. A scripted scroll on the
  emulator, three runs each with and without the monitor, showed no difference beyond run-to-run noise.
- **Idle:** on a still screen the monitor added at most about 0.6 ms of CPU per second (0.06% of one core), which is
  at the limit of what the 10 ms CPU clock can resolve. The stall timer checks every 100 ms only while frames are being
  drawn and about once a second when nothing is, and stops while the phone is hot or saving power.
- **Launch:** cold start was indistinguishable (about 180 ms both ways) when the emulator was quiet.
- **Logging:** an operation over budget logs at most one line a second.
- **Uploads:** built and sent off the main thread, at most one report of about 2 KB per 10 minutes. Nothing is built or
  sent while sharing is off, while Battery Saver or Low Power Mode is on, or while the device is at a moderate or higher
  thermal state. Android also waits for an unmetered network; iOS refuses expensive and constrained networks. Waking a
  mobile radio costs more battery than the report is worth, so a report is simply tried again at the next chance.
- **Startup:** the sharing setting is read on a background thread, so launch never waits on a preferences file for it.

Not measured: a physical device (all numbers are from the emulator and simulator), and battery drain over hours.
