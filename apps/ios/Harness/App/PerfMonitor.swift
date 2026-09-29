// Local performance monitor (PerfMonitor.kt on Android). It answers "what is slow" without leaving the
// device: operation timings against budgets, how long the main thread stays busy per turn, main-thread
// stalls, startup, memory and thermal state. Nothing is uploaded; Settings > Performance shows it and can
// copy a report. Operations also appear as signpost intervals in Instruments.

import Foundation
import os
import UIKit

/// The operations both apps report, so a number on one platform can be compared with the same number on
/// the other. `apps/parity/perf-contract.json` pins these names and budgets; ParityTests checks them.
enum PerfSpan {
    static let startupFirstFrame = "startup.firstFrame"
    static let navigationOpen = "nav.open"
    static let transcriptRows = "transcript.rows"
    static let markdownParse = "markdown.parse"
    static let homeGroup = "home.group"
    static let sendApply = "send.apply"
    static let mainStall = "main.stall"

    /// Milliseconds an operation may take before it counts as slow (one 60 Hz frame is 16.7).
    static let budgetsMs: [String: Double] = [
        startupFirstFrame: 1000,
        navigationOpen: 100,
        transcriptRows: 8,
        markdownParse: 4,
        homeGroup: 4,
        sendApply: 8,
        mainStall: 100,
    ]
}

/// Timing for one named operation over the last `capacity` runs.
struct SpanStat: Equatable {
    let name: String
    let count: Int
    let p50: Double
    let p95: Double
    let max: Double
    /// Lifetime time spent in this operation, so the list can put the costliest first.
    let totalMs: Double
    /// Runs that went over the operation's budget.
    let overBudget: Int
}

/// Keeps a bounded window of durations per operation name.
final class PerfRecorder: @unchecked Sendable {
    private final class Series {
        var ring: [Double]
        var next = 0
        var filled = 0
        var count = 0
        var totalMs = 0.0
        var max = 0.0
        var overBudget = 0
        init(capacity: Int) { ring = Array(repeating: 0, count: capacity) }
    }

    private let capacity: Int
    private let lock = NSLock()
    private var series: [String: Series] = [:]
    private var order: [String] = []

    init(capacity: Int = 128) { self.capacity = capacity }

    func record(_ name: String, ms: Double, budgetMs: Double = .greatestFiniteMagnitude) {
        lock.lock(); defer { lock.unlock() }
        let s: Series
        if let existing = series[name] { s = existing } else {
            s = Series(capacity: capacity)
            series[name] = s
            order.append(name)
        }
        s.ring[s.next] = ms
        s.next = (s.next + 1) % capacity
        if s.filled < capacity { s.filled += 1 }
        s.count += 1
        s.totalMs += ms
        if ms > s.max { s.max = ms }
        if ms > budgetMs { s.overBudget += 1 }
    }

    func stats() -> [SpanStat] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { name -> SpanStat? in
            guard let s = series[name] else { return nil }
            let window = Array(s.ring.prefix(s.filled)).sorted()
            return SpanStat(name: name, count: s.count,
                            p50: Self.percentile(window, 0.50), p95: Self.percentile(window, 0.95),
                            max: s.max, totalMs: s.totalMs, overBudget: s.overBudget)
        }
        .sorted { $0.totalMs > $1.totalMs }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        series.removeAll()
        order.removeAll()
    }

    /// Nearest-rank percentile of an ascending array.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = min(max(Int((q * Double(sorted.count)).rounded(.up)), 1), sorted.count)
        return sorted[rank - 1]
    }
}

struct MainThreadSummary: Equatable {
    let turns: Int
    let slow: Int
    let frozen: Int
    let p50: Double
    let p95: Double
    let worst: Double
    var slowPercent: Double { turns == 0 ? 0 : 100 * Double(slow) / Double(turns) }
}

/// Counts how long the main thread stays busy each time the run loop wakes. A turn over one frame's
/// budget is a dropped frame when the screen is animating, and a laggy tap when it is not, which is why
/// this is the closest cross-app match for Android's frame counts.
final class MainThreadTally: @unchecked Sendable {
    /// One 60 Hz frame; a turn longer than this is slow.
    static let budgetMs = 1000.0 / 60.0
    /// Anything over this is frozen (Android's own cut-off).
    static let frozenMs = 700.0

    private let lock = NSLock()
    private let durations = PerfRecorder(capacity: 512)
    private var turns = 0
    private var slow = 0
    private var frozen = 0

    func add(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        turns += 1
        durations.record("turn", ms: ms)
        if ms > Self.frozenMs { frozen += 1 }
        if ms > Self.budgetMs { slow += 1 }
    }

    func snapshot() -> MainThreadSummary {
        lock.lock(); defer { lock.unlock() }
        let stat = durations.stats().first
        return MainThreadSummary(turns: turns, slow: slow, frozen: frozen,
                                 p50: stat?.p50 ?? 0, p95: stat?.p95 ?? 0, worst: stat?.max ?? 0)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        turns = 0; slow = 0; frozen = 0
        durations.reset()
    }
}

struct MemorySnapshot: Equatable {
    /// What the system counts against the app (the number the jetsam limit uses).
    let footprintMb: Int
}

final class Perf: @unchecked Sendable {
    static let shared = Perf()

    let recorder = PerfRecorder()
    let turns = MainThreadTally()

    private static let signposter = OSSignposter(subsystem: "harness.codegraff.ios", category: "perf")
    private static let log = Logger(subsystem: "harness.codegraff.ios", category: "perf")

    private let lock = NSLock()
    private var started: [String: CFAbsoluteTime] = [:]
    private var observer: CFRunLoopObserver?
    private var turnStart: CFAbsoluteTime = 0
    private(set) var startupMs: Int?

    /// Stale-interaction cut-off: a tap that never showed a new page leaves its start behind.
    private static let staleInteractionMs = 5000.0

    func record(_ name: String, ms: Double) {
        let budget = PerfSpan.budgetsMs[name] ?? .greatestFiniteMagnitude
        recorder.record(name, ms: ms, budgetMs: budget)
        if ms > budget {
            Self.log.warning("\(name, privacy: .public) took \(ms, format: .fixed(precision: 1)) ms (budget \(Int(budget)) ms)")
        }
    }

    /// Times `body`, records it under `name` and shows it as a signpost interval in Instruments.
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval("span", "\(name, privacy: .public)")
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            signposter.endInterval("span", state)
            shared.record(name, ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return try body()
    }

    // MARK: Interactions: a tap starts one, the destination finishes it once it has appeared.

    func startInteraction(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        started[name] = CFAbsoluteTimeGetCurrent()
    }

    func finishInteraction(_ name: String) {
        lock.lock()
        let start = started.removeValue(forKey: name)
        lock.unlock()
        guard let start else { return }
        // Wait for the run loop to commit what onAppear put on screen.
        DispatchQueue.main.async { [self] in
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if ms < Self.staleInteractionMs { record(name, ms: ms) }
        }
    }

    // MARK: Startup

    private var markedFirstFrame = false

    /// Call once the first screen has appeared. Only a launch counts; returning from the background does not.
    func markFirstFrame() {
        guard !markedFirstFrame else { return }
        markedFirstFrame = true
        guard let launched = Self.processStart() else { return }
        DispatchQueue.main.async { [self] in
            let ms = max(0, Date().timeIntervalSince(launched) * 1000)
            startupMs = Int(ms)
            record(PerfSpan.startupFirstFrame, ms: ms)
        }
    }

    /// The process start time. An OS pre-warmed launch starts earlier than the user's tap, so this
    /// can read long on a pre-warmed launch.
    static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }

    // MARK: Main-thread turns

    /// Starts timing each main run loop turn (wake to sleep). Idle costs nothing: the observer only runs
    /// when the loop does.
    func startWatching() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let obs = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, Int.max) { [unowned self] _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                turnStart = now
            } else if turnStart > 0 {
                let ms = (now - turnStart) * 1000
                turnStart = 0
                turns.add(ms: ms)
                if ms >= 50 { record(PerfSpan.mainStall, ms: ms) }
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    // MARK: Device

    func memory() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return MemorySnapshot(footprintMb: result == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : 0)
    }

    static var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    func reset() {
        recorder.reset()
        turns.reset()
    }

    /// Plain text a user can paste into an issue: numbers only, no chat content, names or identifiers.
    func report(version: String) -> String {
        let t = turns.snapshot()
        let stats = recorder.stats()
        var lines = [
            "Harness performance · iOS \(version) · \(UIDevice.current.model) · \(UIDevice.current.systemVersion)",
            "Startup: \(startupMs.map { "\($0) ms to first frame" } ?? "not measured this run")",
            String(format: "Main thread: %d turns, slow %d (%.1f%%), frozen %d; median %.1f ms, 95th %.1f ms, worst %.0f ms",
                   t.turns, t.slow, t.slowPercent, t.frozen, t.p50, t.p95, t.worst),
            "Memory: \(memory().footprintMb) MB footprint · thermal \(Self.thermalLabel)"
                + (ProcessInfo.processInfo.isLowPowerModeEnabled ? " · Low Power Mode" : ""),
            "Operations (median / 95th / worst ms, over budget):",
        ]
        for s in stats {
            lines.append(String(format: "  %@ ×%d: %.1f / %.1f / %.1f, %d over", s.name, s.count, s.p50, s.p95, s.max, s.overBudget))
        }
        return lines.joined(separator: "\n")
    }
}
