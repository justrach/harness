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
