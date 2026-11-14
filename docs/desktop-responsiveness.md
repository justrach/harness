# Desktop updates and responsiveness

## Updates

Nano checks the stable release manifest at startup and hourly while running,
including after wake. Only one check may be in flight; failures back off rather
than retrying per frame. This is distinct from the engine's existing hourly
checker. Checks do not force a restart or interrupt a conversation.

Installed macOS bundles can use the existing verified update path. Other desktop
installations must not be presented as automatically replaceable when their
packaging does not support it. Developer/source builds are report-only. See
Settings → Devices for update status and the explicit install/restart action.

## Enable responsiveness sharing

Settings → Notifications → Privacy → **Share anonymous responsiveness stats**.
This is a new, **off-by-default opt-in**, independent of the old, unwired Nano
performance preference. Debug, hidden, screenshot, replay and test applications
do not upload. Opting out clears the in-memory window and invalidates a queued
upload. An HTTP request already in progress cannot be retracted.

The release desktop app counts completed CPU frames into fixed histograms. The
collector callback runs once after NanoUI's CPU build/layout/paint work, including
retained scrolling. It never reads the local frame log or conversation objects.
No per-frame network requests, allocations or log writes are added. Eligible
release apps start one sleeping worker before opening the window. A fixed
single-slot handoff replaces per-upload thread creation and joining on the UI
thread. Busy workers are skipped without waiting; their slot is never overwritten.
Sending is best effort, off-main, at most once per ten minutes on an active frame.
Quiet or background windows do not wake to upload. Failed batches are dropped, not spooled
to disk or retried in a loop. The next active interval can send fresh data.

### What the numbers mean

| OTLP histogram | Meaning |
| --- | --- |
| `harness.desktop.frame.build` | View/tree construction CPU milliseconds |
| `harness.desktop.frame.layout` | Text measurement/layout CPU milliseconds |
| `harness.desktop.frame.paint` | Building CPU draw instances, not GPU time |
| `harness.desktop.frame.cpu` | Sum of the three CPU stages |
| `harness.desktop.frame.interval` | Gap between consecutive demand-driven CPU frames in the same cohort, in milliseconds |

Intervals exclude background windows, idle-to-active gaps, cohort transitions
and gaps over one second (suspend/resume). They are **not presented FPS, GPU
completion, input-to-photon latency, or a 120 Hz guarantee**. Retained frames have
zero build/layout/paint cost; the scene-shift/renderer cost is not measured by
these CPU stage counters. Long active stalls over one second are excluded from
cadence, not silently counted as smooth frames; CPU-stage histograms still
retain measured stage costs up to 60 seconds. Missing samples must remain
"no data", never be displayed as zero latency.

Cohorts are deliberately coarse and fixed-cardinality:

- resource: app release version, OS (`darwin`, `windows`, `linux`), CPU architecture;
- point: interaction (`scroll`, `input`, `animation`, `other`), pane count
  (`single`, `split`, `many` = three or more), renderer (`metal`, `d3d11`,
  `opengl`, `cpu`).

There are no chat, project, account, installation, launch, device or trace IDs;
no hostnames, paths, keys, pointer coordinates, screen sizes, OS versions,
hardware models, text, URLs, exemplars or arbitrary tags. Event presence is a
boolean used for classification; the event's contents are never retained.
Version strings accept numeric dotted release components only. Window timestamps
are rounded down to whole minutes. Storage is fixed-size and each histogram cell
has a one-million-sample cap. Invalid/nonfinite samples are rejected.

### Collection and fleet views

Batches use OTLP/HTTP JSON delta histograms at the existing metrics collector,
`https://otel.codegraff.com/v1/metrics`, with `service.name=harness.desktop`.
Transport does not attach authentication, cookies, persistent identity or a
system-generated identifying User-Agent, and refuses redirects. Requests time
out after ten seconds and do not read response bodies. Mac uses an ephemeral
native TLS session; Windows and Linux use a fresh certificate-validating client.

Use the accompanying `desktop-responsiveness-dashboard.json` in Grafana with a
Prometheus-compatible OTLP backend. It assumes standard underscore/unit suffix
translation and promotion of `os.type`, `host.arch`, and `service.version` to
`os_type`, `host_arch`, and `service_version`. Confirm these mappings at your
collector before importing; the client does not configure or deploy the backend.
The receiver must sum delta histograms across contributors and, when exporting
Prometheus counters, convert deltas to cumulative counts (for example with a
`deltatocumulative` processor). Do not scrape each delta as if it were cumulative.
The dashboard groups latency by OS, with version, architecture, pane and renderer
filters. A 24-hour window and five-minute refresh suit ten-minute aggregate
uploads; this is asynchronous fleet reporting, not a live per-frame monitor.

The histograms allow fleet percentiles to be computed by summing bucket counts
before computing quantiles. They do not permit counting unique people or linking
launches. The dashboard requires at least 100 frame samples for a percentile
series to reduce misleading tiny samples; this is **not** a 100-person privacy
guarantee. Keep an unfiltered sample-volume panel beside the percentiles.

### Server-side privacy requirements

The payload is identifier-free, but the network edge necessarily sees source IPs.
Do not claim irreversible anonymity based on a client change alone. Before
production rollout, collector operators must verify no IP/authorization/hostname
or device-ID enrichment, no request-body/access-log capture, restricted raw-metric
access and a bounded retention policy (90 days or less). Do not combine metrics
with account/authentication logs. Expose only sufficiently populated cohorts in
shared dashboards. These deployment controls are outside this repository; no
real diagnostics or production upload are used by the tests here.

The importable dashboard is an operator artifact, not an automatically published
hosted page. Its panels use aggregate metrics only, no individual drill-down.

## Lean performance contract

`apps/nano/lean-proofs/Nano/Telemetry.lean` proves universal properties of the
executable scheduling/resource policy, rather than assuming telemetry is free:

- disabled/background recording and publication are forbidden;
- each recorder invocation performs at most five histogram additions and 110
  bucket-bound comparisons, independent of conversation/history length;
- each window has 240 histogram cells / 5,520 bucket counters; two fixed windows
  (active and queued/in-flight) use 11,040 counters, never an expanding queue;
- counts saturate at one million even after arbitrary-length sample sequences;
- at most one upload is queued/in flight, successful handoffs are at least
  600,000 ms apart, and a busy/failed worker never turns publication into a wait;
- the modeled foreground plan contains no serialization, network I/O,
  allocation, thread creation/joining, blocking wait or UI timer scheduling.

The actual Zig recorder and handoff use `performance_policy.zig`; histogram
sizes are compile-time checked against the policy constants. A checked-in set
of **704 Lean-generated cases** exercises every Boolean gate combination at
interval boundaries and clock rollback. Zig checks both its pure policy and the
real recorder against those witnesses. A narrow source drift guard rejects
costly operations in the foreground entrypoints; it is not a Zig compiler proof.
Runtime regressions additionally test allocation failure, a deliberately blocked
consumer, slot preservation, shutdown and recorder overhead.

Run the reproducible gate from the repository root:

```sh
python3 scripts/check-nano-telemetry-proof.py
```

It compiles all seven Lean kernels, checks generated witnesses for drift, then
runs the focused Nano telemetry tests. `--update-vectors` regenerates witnesses
only for an intentional, reviewed policy change. All inputs are synthetic; no
metrics are sent. The timing test prints microseconds per recorder call and
uses a generous 100 µs regression alarm, **not** a cross-platform latency promise.

### What is not proved

Lean verifies this abstract policy, not the compiler, floating-point operations,
OS/FFI implementation, thread scheduling, GPU presentation, or physical-device
frame rate. Finite validity is modeled as a Boolean and timestamps/counts as
non-wrapping naturals; Zig guards invalid floats and uses saturating arithmetic.
The 110 comparisons bound covers histogram search, not every instruction in a
callback. Publication also scans/copies a fixed-size window and wakes the worker;
startup allocates one thread, and teardown may join it. Even off-main work can
compete for CPU/cache resources. This is bounded, nonblocking instrumentation,
**not a proof of literally zero overhead or guaranteed 120 FPS**. Real platform
measurements remain necessary, alongside the proof and regression tests.
