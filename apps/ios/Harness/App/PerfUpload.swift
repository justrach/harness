// The anonymous performance batch and when it may be sent (PerfStats.kt and PerfUpload.kt on Android). It is the
// desktop app's format: samples are counted into fixed ranges, so batches from any number of launches add up to exact
// fleet percentiles. Numbers and fixed names only: no chat content, account, device or session identifiers, and the id
// is random per launch. `apps/parity/vectors/perf-stats.json` pins the JSON and the sending rules for both apps.

import Foundation
import UIKit

enum PerfMetric {
    static let appLaunch = "app_launch_ms"
    static let conversationLoad = "conversation_load_ms"
    static let transcriptRows = "transcript_rows_ms"
    static let markdownParse = "markdown_parse_ms"
    static let homeGroup = "home_group_ms"
    static let sendApply = "send_apply_ms"
    static let mainStall = "main_stall_ms"
    /// One run loop turn's length on iOS. Android reports `frame_cost_ms` instead: the two are not the same measure.
    static let mainTurn = "main_turn_ms"

    /// The order metrics appear in a batch. `frame_cost_ms` is Android only and never sent from here.
    static let order = [
        appLaunch, conversationLoad, transcriptRows, markdownParse, homeGroup, sendApply, mainStall, "frame_cost_ms", mainTurn,
    ]

    /// The batch name of each timed operation.
    static let forSpan: [String: String] = [
        PerfSpan.startupFirstFrame: appLaunch,
        PerfSpan.navigationOpen: conversationLoad,
        PerfSpan.transcriptRows: transcriptRows,
        PerfSpan.markdownParse: markdownParse,
        PerfSpan.homeGroup: homeGroup,
        PerfSpan.sendApply: sendApply,
        PerfSpan.mainStall: mainStall,
    ]
}

struct PerfMetricBatch {
    let name: String
    let count: Int
    let sumMs: Double
    let maxMs: Double
    let buckets: [Int]
}

struct PerfWindow {
    let startMs: Int
    let endMs: Int
    let metrics: [PerfMetricBatch]
}

/// Samples since the last upload, counted into the desktop app's fixed ranges. A window that could not be sent is put
/// back and merges into the next one. Recording is a bucket lookup and an add, cheap enough for every run loop turn.
final class PerfHistograms: @unchecked Sendable {
    /// Upper bounds in ms; the last range is everything above. Identical to the desktop app's and the server's.
    static let bucketsMs: [Double] = [
        1.0, 2.0, 4.0, 8.33, 16.67, 33.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0, 500.0, 750.0,
        1000.0, 1500.0, 2000.0, 3000.0, 5000.0, 10000.0, 20000.0, 60000.0,
    ]
    static let bucketCount = bucketsMs.count + 1
    static let maxSampleMs = 60_000.0
    /// Six days: inside the server's seven-day limit on how long a window may be.
    static let maxWindowMs = 6 * 24 * 60 * 60 * 1000

    static func bucketIndex(_ ms: Double) -> Int {
        bucketsMs.firstIndex { ms <= $0 } ?? bucketsMs.count
    }

    private struct Histogram {
        var count = 0
        var sumMs = 0.0
        var maxMs = 0.0
        var buckets = [Int](repeating: 0, count: PerfHistograms.bucketCount)
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Int
    private var metrics: [String: Histogram] = [:]
    private var windowStartMs: Int

    init(now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
        windowStartMs = now()
    }

    func add(_ metric: String, ms: Double) {
        guard ms.isFinite, PerfMetric.order.contains(metric) else { return }
        let clamped = min(max(ms, 0), Self.maxSampleMs)
        lock.lock(); defer { lock.unlock() }
        var h = metrics[metric] ?? Histogram()
        h.buckets[Self.bucketIndex(clamped)] += 1
        h.count += 1
        h.sumMs += clamped
        h.maxMs = max(h.maxMs, clamped)
        metrics[metric] = h
    }

    /// Samples held, across every metric.
    var pendingSamples: Int {
        lock.lock(); defer { lock.unlock() }
        return metrics.values.reduce(0) { $0 + $1.count }
    }

    /// Empties the window; nil when nothing was sampled.
    func take() -> PerfWindow? {
        lock.lock(); defer { lock.unlock() }
        let end = now()
        // The server refuses a window over seven days, and an app can stay alive that long without a flush.
        let start = max(windowStartMs, end - Self.maxWindowMs)
        windowStartMs = end
        let taken = metrics
        metrics.removeAll()
        let batches = PerfMetric.order.compactMap { name -> PerfMetricBatch? in
            guard let h = taken[name], h.count > 0 else { return nil }
            return PerfMetricBatch(name: name, count: h.count, sumMs: h.sumMs, maxMs: h.maxMs, buckets: h.buckets)
        }
        return batches.isEmpty ? nil : PerfWindow(startMs: start, endMs: max(end, start), metrics: batches)
    }

    /// Puts an unsent window back, so its samples go out with the next one.
    func restore(_ window: PerfWindow) {
        lock.lock(); defer { lock.unlock() }
        windowStartMs = min(windowStartMs, window.startMs)
        for m in window.metrics {
            var h = metrics[m.name] ?? Histogram()
            for i in m.buckets.indices { h.buckets[i] += m.buckets[i] }
            h.count += m.count
            h.sumMs += m.sumMs
            h.maxMs = max(h.maxMs, m.maxMs)
            metrics[m.name] = h
        }
    }
}

/// What identifies the batch: the app, the OS and the hardware model, never a person.
struct PerfBatchMeta {
    /// Random and fresh for every launch, in the `install_id` field the desktop format already has.
    let installId: String
    let os: String
    let arch: String
    let appVersion: String
    let osVersion: String
    let device: String
    let refreshHz: Int
}

struct PerfStatsBatch {
    static let schema = "harness.mobile.stats.v1"
    static let maxDeviceLength = 40
    static let maxVersionLength = 32
    static let refreshHzRange = 24...240

    private static let allowedVersionCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-")

    /// What the server accepts in a version: letters, digits and `.+-`, up to 32 characters; anything else becomes `-`.
    static func versionString(_ raw: String) -> String {
        let cleaned = String(String(raw.map { allowedVersionCharacters.contains($0) ? $0 : "-" }).prefix(maxVersionLength))
        return cleaned.isEmpty ? "0" : cleaned
    }

    /// What the server accepts in a device model: letters, digits and ` ,._()-`.
    private static let allowedDeviceCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ,._()-")

    private static func round2(_ x: Double) -> Double { (x * 100 + 0.5).rounded(.down) / 100 }

    let meta: PerfBatchMeta
    let window: PerfWindow

    func json() -> [String: Any] {
        [
            "schema": Self.schema,
            "install_id": meta.installId,
            "app_version": Self.versionString(meta.appVersion),
            "os": meta.os,
            "arch": meta.arch,
            "os_version": meta.osVersion,
            "device": String(String(meta.device.filter { Self.allowedDeviceCharacters.contains($0) }).prefix(Self.maxDeviceLength)),
            "refresh_hz": min(max(meta.refreshHz, Self.refreshHzRange.lowerBound), Self.refreshHzRange.upperBound),
            "window_start_ms": window.startMs,
            "window_end_ms": max(window.endMs, window.startMs),
            "metrics": window.metrics.map { m -> [String: Any] in
                [
                    "name": m.name, "count": m.count,
                    "sum_ms": Self.round2(m.sumMs), "max_ms": Self.round2(m.maxMs),
                    "buckets": m.buckets,
                ]
            },
        ]
    }

    func body() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// When the monitor's own background work (uploads) should hold back. Pinned in `apps/parity/vectors/perf-stats.json`.
enum PerfPolicy {
    /// Thermal labels from either platform that mean the device is already working hard.
    static let hotThermal: Set<String> = ["Moderate", "Severe", "Critical", "Serious"]

    static func deviceIsCalm(lowPower: Bool, thermal: String) -> Bool {
        !lowPower && !hotThermal.contains(thermal)
    }
}

/// Decides when a batch may go out. An endpoint must exist, sharing must be on, the window must have samples, at most
/// one attempt goes out per interval, and samples recorded while nothing can be sent are dropped rather than held for
/// later.
actor PerfUploader {
    static let minIntervalMs = 10 * 60_000

    private let endpoint: String?
    private let enabled: @Sendable () -> Bool
    private let source: PerfHistograms
    private let now: @Sendable () -> Int
    /// Posts the body and returns the HTTP status, or 0 when the connection failed.
    private let post: @Sendable (String, String) async -> Int
    private var lastAttemptAt: Int?
    private var stopped = false

    init(endpoint: String?, enabled: @escaping @Sendable () -> Bool, source: PerfHistograms,
         now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
         post: @escaping @Sendable (String, String) async -> Int) {
        self.endpoint = endpoint
        self.enabled = enabled
        self.source = source
        self.now = now
        self.post = post
    }

    /// True when a batch was sent. A 2xx is sent. 429 and other 4xx keep the samples and start the wait. 400, 413 and
    /// 415 mean the batch itself is wrong, so it is dropped and sending stops for the rest of the launch. 5xx and a
    /// failed connection keep the samples and start no wait: they are tried again at the next chance.
    func flush(meta: PerfBatchMeta) async -> Bool {
        let t = now()
        if let last = lastAttemptAt, t - last < Self.minIntervalMs { return false }
        guard let window = source.take() else { return false }
        guard let endpoint, enabled(), !stopped else { return false }
        let status = await post(endpoint, PerfStatsBatch(meta: meta, window: window).body())
        switch status {
        case 200..<300:
            lastAttemptAt = t
            return true
        case 400, 413, 415:
            stopped = true
            return false
        case 400..<500:
            lastAttemptAt = t
            source.restore(window)
            return false
        default:
            source.restore(window)
            return false
        }
    }
}

/// A plain JSON POST: no cookies, no credentials, no cache, no redirects, and only over https (loopback may use
/// http for tests).
enum PerfTransport {
    static func isAllowed(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint), let scheme = url.scheme, let host = url.host else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// The HTTP status, or 0 when nothing was sent or the connection failed. `configure` lets a test add a stub
    /// protocol; the app passes nothing.
    static func post(_ endpoint: String, _ body: String,
                     configure: (URLSessionConfiguration) -> Void = { _ in }) async -> Int {
        guard isAllowed(endpoint), let url = URL(string: endpoint) else { return 0 }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        // Never wake the cellular radio or spend Low Data Mode's allowance on a two kilobyte report: on mobile data
        // the request fails at once and is tried again at the next chance.
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.waitsForConnectivity = false
        config.networkServiceType = .background
        configure(config)
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return 0 }
        return http.statusCode
    }
}

/// Whether anonymous batches are sent. On unless the person turns it off in Settings, and only when there is somewhere to send.
enum PerfSharing {
    static let key = "share-performance"

    /// Pinned in `apps/parity/vectors/perf-stats.json`.
    static let defaultEnabled = true

    /// Where batches go: the same stats endpoint the desktop app uses. Unset until the server accepts iOS and Android
    /// batches; with no endpoint nothing is offered and nothing is sent.
    static let endpoint: String? = nil

    static var available: Bool { endpoint != nil }
    /// `bool(forKey:)` reads an unset key as false, which would make "never chosen" mean off.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultEnabled }

    private static let installId = UUID().uuidString.lowercased()
    private static let uploader = PerfUploader(endpoint: endpoint, enabled: { enabled }, source: Perf.shared.histograms,
                                               post: { await PerfTransport.post($0, $1) })

    private static let isDebugBuild: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    /// Called when the app goes to the background. A batch is only built, and only sent, when sharing is on, this is
    /// not a debug build, and the phone is neither hot nor in Low Power Mode; the post itself runs at utility priority
    /// off the main thread and refuses mobile data. Samples that could not go now stay for the next attempt; samples
    /// recorded while sharing is off are dropped and never sent later.
    @MainActor
    static func flush() {
        guard available else { return }
        if !enabled || isDebugBuild { _ = Perf.shared.histograms.take(); return }
        guard PerfPolicy.deviceIsCalm(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: Perf.thermalLabel) else { return }
        let meta = batchMeta()
        Task.detached(priority: .utility) { _ = await uploader.flush(meta: meta) }
    }

    @MainActor
    private static func batchMeta() -> PerfBatchMeta {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
        #if arch(arm64)
        let arch = "aarch64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "other"
        #endif
        return PerfBatchMeta(installId: installId, os: "ios", arch: arch, appVersion: "\(short)+\(build)",
                             osVersion: UIDevice.current.systemVersion, device: modelIdentifier(),
                             refreshHz: screen?.maximumFramesPerSecond ?? 60)
    }

    /// The hardware model ("iPhone18,1"), not the name the owner gave the phone.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}
