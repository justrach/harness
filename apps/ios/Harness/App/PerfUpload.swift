// The anonymous performance report and when it may be sent (PerfUpload.kt on Android). Numbers and fixed
// names only: no chat content, account, device or session identifiers. `launchId` is random per process, so
// the reports of one launch can be joined on the server but never tied to a person or to the next launch.
// `apps/parity/vectors/perf-report.json` pins the JSON and the sending rules for both apps.

import Foundation
import UIKit

struct PerfReport {
    struct Frames {
        let total: Int, slow: Int, frozen: Int
        let p50: Double, p95: Double, worst: Double
    }

    static let schema = 1
    static let maxDeviceLength = 40

    let launchId: String
    let platform: String
    let appVersion: String
    let osVersion: String
    let device: String
    let build: String
    let refreshHz: Int
    let startupMs: Int?
    /// "frame" (Android) or "turn" (iOS main run loop turn): the two are not the same measure.
    let frameKind: String
    let frames: Frames
    let thermal: String
    let lowPower: Bool
    let memoryMb: Int
    let spans: [SpanStat]

    private static func round1(_ x: Double) -> Double { (x * 10 + 0.5).rounded(.down) / 10 }

    func json() -> [String: Any] {
        [
            "schema": Self.schema,
            "launchId": launchId,
            "platform": platform,
            "appVersion": appVersion,
            "osVersion": osVersion,
            "device": String(device.prefix(Self.maxDeviceLength)),
            "build": build,
            "refreshHz": refreshHz,
            "startupMs": startupMs.map { $0 as Any } ?? NSNull(),
            "frameKind": frameKind,
            "frames": [
                "total": frames.total, "slow": frames.slow, "frozen": frames.frozen,
                "p50": Self.round1(frames.p50), "p95": Self.round1(frames.p95), "worst": Self.round1(frames.worst),
            ] as [String: Any],
            "thermal": thermal,
            "lowPower": lowPower,
            "memoryMb": memoryMb,
            // Only the operations both apps define: a name minted somewhere else can never carry content out.
            "spans": spans.filter { PerfSpan.budgetsMs[$0.name] != nil }.map { s -> [String: Any] in
                [
                    "name": s.name, "count": s.count,
                    "p50": Self.round1(s.p50), "p95": Self.round1(s.p95), "max": Self.round1(s.max),
                    "totalMs": Self.round1(s.totalMs), "overBudget": s.overBudget,
                ]
            },
        ]
    }

    func body() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Decides when a report may go out. An endpoint must exist, sharing must be on, the session must have run
/// enough turns to mean something, at most one report goes out per interval, and a failed post does not start
/// the wait.
actor PerfUploader {
    static let minFrames = 60
    static let minIntervalMs = 10 * 60_000

    private let endpoint: String?
    private let enabled: @Sendable () -> Bool
    private let now: @Sendable () -> Int
    private let post: @Sendable (String, String) async -> Bool
    private var lastSentAt: Int?

    init(endpoint: String?, enabled: @escaping @Sendable () -> Bool,
         now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
         post: @escaping @Sendable (String, String) async -> Bool) {
        self.endpoint = endpoint
        self.enabled = enabled
        self.now = now
        self.post = post
    }

    /// True when a report was sent.
    func flush(_ report: PerfReport) async -> Bool {
        guard let endpoint, enabled() else { return false }
        guard report.frames.total >= Self.minFrames else { return false }
        let t = now()
        if let last = lastSentAt, t - last < Self.minIntervalMs { return false }
        let ok = await post(endpoint, report.body())
        if ok { lastSentAt = t }
        return ok
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

    /// `configure` lets a test add a stub protocol; the app passes nothing.
    static func post(_ endpoint: String, _ body: String,
                     configure: (URLSessionConfiguration) -> Void = { _ in }) async -> Bool {
        guard isAllowed(endpoint), let url = URL(string: endpoint) else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        configure(config)
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

/// Whether anonymous reports are sent. On unless the person turns it off in Settings, and only when there is somewhere to send.
enum PerfSharing {
    static let key = "share-performance"

    /// Pinned in `apps/parity/vectors/perf-report.json`.
    static let defaultEnabled = true

    /// Where reports go. Unset until the backend is agreed; with no endpoint nothing is offered and nothing is sent.
    static let endpoint: String? = nil

    static var available: Bool { endpoint != nil }
    /// `bool(forKey:)` reads an unset key as false, which would make "never chosen" mean off.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? defaultEnabled }

    private static let launchId = UUID().uuidString.lowercased()
    private static let uploader = PerfUploader(endpoint: endpoint, enabled: { enabled }, post: { await PerfTransport.post($0, $1) })

    /// Called when the app goes to the background. Cheap when sharing is off: nothing is built.
    @MainActor
    static func flush() {
        guard available, enabled else { return }
        let report = buildReport()
        Task.detached(priority: .utility) { _ = await uploader.flush(report) }
    }

    @MainActor
    static func buildReport() -> PerfReport {
        let perf = Perf.shared
        let t = perf.turns.snapshot()
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
        #if DEBUG
        let kind = "debug"
        #else
        let kind = "release"
        #endif
        return PerfReport(
            launchId: launchId, platform: "ios", appVersion: "\(short) (\(build))",
            osVersion: UIDevice.current.systemVersion, device: modelIdentifier(), build: kind,
            refreshHz: screen?.maximumFramesPerSecond ?? 60, startupMs: perf.startupMs, frameKind: "turn",
            frames: .init(total: t.turns, slow: t.slow, frozen: t.frozen, p50: t.p50, p95: t.p95, worst: t.worst),
            thermal: Perf.thermalLabel, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryMb: perf.memory().footprintMb, spans: perf.recorder.stats())
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
