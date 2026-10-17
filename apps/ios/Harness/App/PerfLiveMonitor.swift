// Demand-driven monitoring: no periodic sampling on quiet screens or in the background.
// The new counters are local only; they never enter PerfHistograms or PerfUpload.
import UIKit

@MainActor
final class PerfLiveMonitor: NSObject {
    static let shared = PerfLiveMonitor()

    private struct Interest {
        var inspection = false
        var scrolling = false
        var streaming = false
    }
    private var interests: [UUID: Interest] = [:]
    private var backgrounded: Bool
    private var sampler: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var lifecycle: [NSObjectProtocol] = []
    var isSampling: Bool { sampler != nil }
    var isMeasuringCadence: Bool { displayLink != nil }

    override init() {
        backgrounded = UIApplication.shared.applicationState == .background
        super.init()
        let center = NotificationCenter.default
        lifecycle = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setBackgrounded(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setBackgrounded(false) }
            },
        ]
    }

    deinit {
        sampler?.cancel()
        displayLink?.invalidate()
        for token in lifecycle { NotificationCenter.default.removeObserver(token) }
    }

    func inspect(_ id: UUID, visible: Bool) {
        interests[id] = visible ? Interest(inspection: true) : nil
        refresh()
    }

    func transcript(_ id: UUID, visible: Bool, scrolling: Bool, streaming: Bool) {
        interests[id] = visible && (scrolling || streaming)
            ? Interest(scrolling: scrolling, streaming: streaming) : nil
        refresh()
    }

    func remove(_ id: UUID) {
        interests.removeValue(forKey: id)
        refresh()
    }

    func setBackgrounded(_ value: Bool) {
        backgrounded = value
        refresh()
    }

    private func refresh() {
        let scrolling = !backgrounded && interests.values.contains { $0.scrolling }
        let streaming = !backgrounded && interests.values.contains { $0.streaming }
        Perf.shared.cadence.setActive(.scrolling, scrolling)
        Perf.shared.cadence.setActive(.streaming, streaming)
        let needed = !backgrounded && !interests.isEmpty
        if needed, sampler == nil {
            Perf.shared.resources.pause()
            Perf.shared.fileWrites.pause()
            sampler = Task { [weak self] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    let sample = ProcessResourceSample.read()
                    Perf.shared.resources.sample(sample)
                    Perf.shared.fileWrites.sampleRate(at: sample.uptime)
                    do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100)) }
                    catch { return }
                }
            }
        } else if !needed {
            sampler?.cancel()
            sampler = nil
            Perf.shared.resources.pause()
            Perf.shared.fileWrites.pause()
        }
        if scrolling || streaming {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        Perf.shared.cadence.record(timestamp: link.timestamp,
                                   expectedInterval: link.targetTimestamp - link.timestamp)
    }
}
