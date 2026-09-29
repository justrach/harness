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

Off by default, and only offered once a destination is configured (`PerfSharing.endpoint` on each app, unset until the
backend is agreed; with no endpoint the toggle is hidden and nothing is built or sent). When someone turns on
"Share anonymous performance data", the app sends one report as the app goes to the background.

- **Content:** `vectors/perf-report.json` pins the JSON both apps produce: app, OS and device model (the hardware
  identifier, never the name the owner gave it, capped at 40 characters), refresh rate, startup, frame or turn counts,
  memory, thermal state, and the fixed operation names above. Any other name is dropped before it is sent.
- **Identity:** a random id per launch, so one launch's reports can be joined but never linked to a person or to the
  next launch. No account, install, device or session identifier, and no chat content.
- **Rules:** an endpoint exists, sharing is on, the session drew at least 60 frames or turns, at most one report per
  10 minutes, and a failed post does not start the wait. Both apps test these against the same vectors.
- **Transport:** a JSON POST over https (loopback http for tests), with no cookies, credentials, cache or redirects.
- **Store listings:** turning this on means declaring diagnostics (performance data, not linked to the user) in the App
  Store privacy answers and the Play data safety form.
