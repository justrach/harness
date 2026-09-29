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

## Sharing anonymous performance numbers

All the apps report to the same stats endpoint, `POST /v1/harness/stats`, in the same shape: samples counted into fixed
ranges (22 bounds from 1 ms to 60 s plus an overflow range), so batches from any number of launches and devices add up
to exact fleet percentiles. The desktop app already did this (`crates/ui/src/perf_stats.rs`); iOS and Android now send
the same batch with `os` set to `ios` or `android` and their own metric names.

On by default, with a "Share anonymous performance data" switch in Settings to turn it off, and only active once the
server accepts mobile batches (`PerfSharing.endpoint` on each app, unset until then; with no endpoint the switch is
hidden and nothing is sent). While it is on, a batch goes out as the app goes to the background. A person who has turned
it off stays off: only a never-chosen setting reads as on.

- **Content:** `vectors/perf-stats.json` pins the JSON both apps produce (`schema` `harness.mobile.stats.v1`): `os`,
  `arch`, app and OS version, the hardware model (never the name the owner gave it, capped at 40 characters), the
  refresh rate, the time window, and per metric a count, sum, max and the range counts. Metric names outside the list
  are dropped before sending, and each sample is clamped to 0..60000 ms.
- **Identity:** `install_id` is a random v4 UUID made fresh for every launch, so one launch's batches can be joined but
  never linked to a person or to the next launch. The desktop app keeps one per install instead, in its own file. No
  account, device or session identifier, and no chat content.
- **Metrics:** `app_launch_ms` and `conversation_load_ms` mean the same as on desktop. The rest are mobile's own:
  `transcript_rows_ms`, `markdown_parse_ms`, `home_group_ms`, `send_apply_ms`, `main_stall_ms`, and one frame measure:
  `frame_cost_ms` on Android (a frame's render cost) or `main_turn_ms` on iOS (a main run loop turn). Those two differ,
  so they are never compared with each other.
- **Rules:** an endpoint exists, sharing is on, the window has samples, at most one attempt per 10 minutes. Samples that
  could not go stay and merge into the next window; samples recorded while sharing is off are dropped and never sent
  later. Both apps test these against the same vectors.
- **Never uploaded:** debug builds, or while Battery Saver or Low Power Mode is on, or at a moderate or higher thermal
  state. Android also waits for an unmetered network; iOS refuses expensive and constrained networks.
- **Transport:** a JSON POST over https (loopback http for tests), with no cookies, credentials, cache or redirects.
- **Store listings and disclosure:** collecting on by default means declaring diagnostics (performance data, not linked
  to the user) in the App Store privacy answers and the Play data safety form, and saying so in the privacy policy
  before the endpoint is switched on.

How the app treats the server's answer:

| Status | Meaning | The app |
| --- | --- | --- |
| 2xx | stored, or accepted and dropped by a cap | counts as sent |
| 429, other 4xx | rate limited, or for example a route not deployed yet | keeps the samples, starts the 10 minute wait |
| 400, 413, 415 | the batch is invalid, too large, or not JSON | drops it and stops sending for the rest of the launch |
| 5xx, no connection | server or network trouble | keeps the samples, no wait, tries again at the next chance |

## What it costs the device

The monitor must not be what slows the app or drains the phone, so its cost is bounded and was measured.

- **Per call:** recording an operation takes about 0.07 µs on Android and tallying a frame, including its range count, about 0.07 µs (a unit test
  fails above 5 µs; the iOS test fails above 25 µs in a debug build, to catch a hundredfold regression).
- **Frames:** the frame listener runs on its own thread and only while the app is in front. A scripted scroll on the
  emulator, three runs each with and without the monitor, showed no difference beyond run-to-run noise.
- **Idle:** on a still screen the monitor added at most about 0.6 ms of CPU per second (0.06% of one core), which is
  at the limit of what the 10 ms CPU clock can resolve. The stall timer checks every 100 ms only while frames are being
  drawn and about once a second when nothing is, and stops while the phone is hot or saving power.
- **Launch:** cold start was indistinguishable (about 180 ms both ways) when the emulator was quiet.
- **Logging:** an operation over budget logs at most one line a second.
- **Uploads:** built and sent off the main thread, at most one batch of a few kilobytes per 10 minutes. Nothing is built
  or sent while sharing is off, in a debug build, while Battery Saver or Low Power Mode is on, or at a moderate or higher
  thermal state. Android also waits for an unmetered network; iOS refuses expensive and constrained networks. Waking a
  mobile radio costs more battery than the batch is worth, so it is simply tried again at the next chance.
- **Startup:** the sharing setting is read on a background thread, so launch never waits on a preferences file for it.

Not measured: a physical device (all numbers are from the emulator and simulator), and battery drain over hours.
