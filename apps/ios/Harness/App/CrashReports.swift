// Crash and hang reports from iOS (MetricKit). iOS hands the app a report on
// a later launch (usually the next one) for each crash, hang, CPU or disk-write
// overuse, and slow launch it saw. They're kept on this iPhone, newest 50, and
// each is sent once to the Harness edge (POST /diagnostics/crash-reports) while
// signed in, unless "Send to Harness" is off in Settings → Crash reports. The
// stacks hold code addresses only; `scripts/symbolicate-metrickit.py` turns
// them into function names with the build's dSYMs (kept by testflight.yml).

import CryptoKit
import Foundation
import MetricKit

final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReports()

    static let keep = 50

    struct Report: Identifiable, Equatable {
        var id: String { file.lastPathComponent }
        let file: URL
        let receivedAt: Date
        let summary: Summary
    }

    /// What a report holds, read from MetricKit's JSON.
    struct Summary: Equatable {
        var crashes = 0
        var hangs = 0
        var cpu = 0
        var diskWrites = 0
        var launches = 0
        /// The build the first diagnostic came from (`appBuildVersion`).
        var build: String?
        /// One line saying what happened, for the list.
        var headline = "Diagnostics"
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CrashReports", isDirectory: true)
    }

    /// At launch: the reports iOS has been holding, and every later one.
    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads.map { $0.jsonRepresentation() })
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads.map { $0.jsonRepresentation() })
        uploadPending()
    }

    // MARK: Sending reports to Harness

    /// Settings → Crash reports → "Send to Harness". On unless turned off.
    static let sendKey = "crashReports.send"
    /// One upload: the edge takes at most 10 reports and 1 MiB per request.
    static let batchCount = 10
    static let batchBytes = 900_000

    var sending: Bool { UserDefaults.standard.object(forKey: Self.sendKey) as? Bool ?? true }

    private let lock = NSLock()
    private var config: AppConfig?
    private var uploading = false

    /// The signed-in edge to send reports to (nil once signed out); sends what's waiting.
    func connect(_ config: AppConfig?) {
        lock.withLock { self.config = config }
        uploadPending()
    }

    /// Sends every saved report the edge hasn't taken yet, oldest first. One run at a time; a
    /// failure leaves the rest for the next launch, sign-in or return to the foreground.
    func uploadPending(in folder: URL = CrashReports.folder) {
        guard sending else { return }
        let config: AppConfig? = lock.withLock {
            guard !uploading, let config, config.mode == .codegraff else { return nil }
            uploading = true
            return config
        }
        guard let config else { return }
        Task.detached(priority: .utility) {
            defer { self.lock.withLock { self.uploading = false } }
            await self.upload(to: config, folder: folder)
        }
    }

    private func upload(to config: AppConfig, folder: URL) async {
        var sent = Self.sentNames(in: folder)
        let waiting = reports(in: folder).reversed().filter { !sent.contains($0.id) }
            .compactMap { report in (try? Data(contentsOf: report.file)).map { (report.id, $0) } }
        for batch in Self.batches(waiting) {
            guard var request = await config.crashReportsRequest() else { return }
            request.httpBody = Self.body(batch.map(\.data))
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 413: a report the edge will never take; dropping it beats resending it every launch.
            guard status == 200 || status == 413 else { return }
            sent.formUnion(batch.map(\.id))
            Self.markSent(sent, in: folder)
        }
    }

    /// Reports in upload batches of at most `batchCount` and about `batchBytes`; a report
    /// larger than that goes alone (and the edge refuses it).
    static func batches(_ reports: [(id: String, data: Data)], count: Int = batchCount,
                        bytes: Int = batchBytes) -> [[(id: String, data: Data)]] {
        var out: [[(id: String, data: Data)]] = []
        var current: [(id: String, data: Data)] = []
        var size = 0
        for report in reports {
            if !current.isEmpty && (current.count == count || size + report.data.count > bytes) {
                out.append(current)
                current = []
                size = 0
            }
            current.append(report)
            size += report.data.count + 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// A JSON array of the reports as iOS wrote them.
    static func body(_ reports: [Data]) -> Data {
        var body = Data("[".utf8)
        for (i, report) in reports.enumerated() {
            if i > 0 { body.append(Data(",".utf8)) }
            body.append(report)
        }
        body.append(Data("]".utf8))
        return body
    }

    /// The report files the edge has taken, listed beside them (not `.json`, so not a report).
    static func sentNames(in folder: URL) -> Set<String> {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("sent.list"), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Records `sent`, keeping only reports still on the iPhone.
    static func markSent(_ sent: Set<String>, in folder: URL) {
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let text = sent.intersection(present).sorted().joined(separator: "\n")
        try? Data(text.utf8).write(to: folder.appendingPathComponent("sent.list"),
                                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Writes each report once (iOS can hand the same one over again), then
    /// keeps the newest `keep`.
    func save(_ reports: [Data], in folder: URL = CrashReports.folder, now: Date = Date()) {
        guard !reports.isEmpty else { return }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        for data in reports {
            let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
            if (try? files.contentsOfDirectory(atPath: folder.path))?.contains(where: { $0.hasSuffix("-\(digest).json") }) == true {
                continue
            }
            let stamp = Int(now.timeIntervalSince1970 * 1000)
            try? data.write(to: folder.appendingPathComponent("\(stamp)-\(digest).json"),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let saved = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for old in saved.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .dropFirst(Self.keep) {
            try? files.removeItem(at: old)
        }
    }

    /// Newest first.
    func reports(in folder: URL = CrashReports.folder) -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                let millis = Double(file.lastPathComponent.split(separator: "-").first ?? "") ?? 0
                return Report(file: file, receivedAt: Date(timeIntervalSince1970: millis / 1000),
                              summary: Self.summary(of: data))
            }
    }

    func deleteAll(in folder: URL = CrashReports.folder) {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Reading MetricKit's JSON

    static func summary(of data: Data) -> Summary {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Summary() }
        func list(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        func meta(_ item: [String: Any]?) -> [String: Any] { item?["diagnosticMetaData"] as? [String: Any] ?? [:] }
        let crashes = list("crashDiagnostics"), hangs = list("hangDiagnostics")
        let cpu = list("cpuExceptionDiagnostics"), disk = list("diskWriteExceptionDiagnostics")
        let launches = list("appLaunchDiagnostics")
        var summary = Summary(crashes: crashes.count, hangs: hangs.count, cpu: cpu.count, diskWrites: disk.count,
                              launches: launches.count)
        let first = crashes.first ?? hangs.first ?? cpu.first ?? disk.first ?? launches.first
        summary.build = meta(first)["appBuildVersion"] as? String
        if let crash = crashes.first {
            summary.headline = crashHeadline(meta(crash))
        } else if let hang = hangs.first {
            let duration = meta(hang)["hangDuration"] as? String
            summary.headline = duration.map { "Hang (\($0))" } ?? "Hang"
        } else if !cpu.isEmpty {
            summary.headline = "Too much CPU in the background"
        } else if !disk.isEmpty {
            summary.headline = "Heavy disk writes"
        } else if let launch = launches.first {
            let duration = meta(launch)["launchDuration"] as? String
            summary.headline = duration.map { "Slow launch (\($0))" } ?? "Slow launch"
        }
        return summary
    }

    /// The watchdog's own words when there are some (`0x8badf00d` and its
    /// explanation), otherwise the exception and signal.
    static func crashHeadline(_ meta: [String: Any]) -> String {
        if let reason = meta["terminationReason"] as? String,
           let line = reason.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty {
            return "Crash: " + (line.count > 90 ? String(line.prefix(89)) + "…" : line)
        }
        let signal = (meta["signal"] as? NSNumber).map { signalName($0.intValue) }
        let exception = (meta["exceptionType"] as? NSNumber).map { exceptionName($0.intValue) }
        let parts = [exception, signal].compactMap { $0 }
        return parts.isEmpty ? "Crash" : "Crash: " + parts.joined(separator: " · ")
    }

    static func signalName(_ number: Int) -> String {
        switch number {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        default: "signal \(number)"
        }
    }

    static func exceptionName(_ number: Int) -> String {
        switch number {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "exception \(number)"
        }
    }
}
