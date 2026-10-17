// Display-link callback cadence during visible scrolling and live replies.
// A delayed callback estimates missed refresh opportunities, not GPU-rendered frames.
import Foundation

enum PerfActivity: String, CaseIterable {
    case scrolling = "Scrolling"
    case streaming = "Live reply"
}

struct CadenceSummary {
    let intervals: Int
    let averageHz: Double?
    let p95Ms: Double?
    let worstMs: Double?
    let missedRefreshes: Int
}

final class CadenceTally: @unchecked Sendable {
    private struct Series {
        var active = false
        var last: TimeInterval?
        var expected: TimeInterval = 0
        var intervals = 0
        var elapsed: TimeInterval = 0
        var missed = 0
    }
    private let lock = NSLock()
    private var series: [PerfActivity: Series] = [:]
    private let durations = PerfRecorder(capacity: 256)

    func setActive(_ activity: PerfActivity, _ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        var s = series[activity] ?? Series()
        if s.active != active { s.last = nil }
        s.active = active
        series[activity] = s
    }

    func record(timestamp: TimeInterval, expectedInterval: TimeInterval) {
        guard timestamp.isFinite, expectedInterval.isFinite, expectedInterval > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for activity in PerfActivity.allCases {
            guard var s = series[activity], s.active else { continue }
            if let last = s.last, timestamp > last {
                let elapsed = timestamp - last
                // Don't call a legitimate switch from 120 Hz to 60 Hz a missed frame.
                let expected = max(s.expected, expectedInterval)
                let slots = min(elapsed / expected, Double(Int.max / 2))
                s.missed += max(0, Int(slots.rounded()) - 1)
                s.intervals += 1
                s.elapsed += elapsed
                durations.record(activity.rawValue, ms: elapsed * 1000)
            }
            s.last = timestamp
            s.expected = expectedInterval
            series[activity] = s
        }
    }

    func snapshot(_ activity: PerfActivity) -> CadenceSummary {
        lock.lock(); defer { lock.unlock() }
        let s = series[activity] ?? Series()
        let stat = durations.stats().first { $0.name == activity.rawValue }
        return CadenceSummary(intervals: s.intervals,
                              averageHz: s.elapsed > 0 ? Double(s.intervals) / s.elapsed : nil,
                              p95Ms: stat?.p95, worstMs: stat?.max, missedRefreshes: s.missed)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        // Keep activity flags: a reset during a live reply must continue sampling.
        for activity in Array(series.keys) {
            let active = series[activity]?.active ?? false
            series[activity] = Series(active: active)
        }
        durations.reset()
    }
}
