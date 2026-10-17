// Logical payload submitted by our file stores, not OS-wide or physical writes.
// No paths, file names, document ids, or contents are retained.
import Foundation

enum PerfFileKind: String, CaseIterable {
    case snapshots = "Snapshots"
    case registry = "Registry"
    case models = "Model cache"
    case attachments = "Attachments"
}

struct FileWriteSummary {
    let bytes: UInt64
    let writes: Int
    let failures: Int
    let bytesPerSecond: Double?
    let byKind: [PerfFileKind: UInt64]
}

final class FileWriteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var writes = 0
    private var failures = 0
    private var byKind: [PerfFileKind: UInt64] = [:]
    private var baseline: (time: TimeInterval, bytes: UInt64)?
    private var rate: Double?

    func record(bytes count: Int, kind: PerfFileKind, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard succeeded else { failures += 1; return }
        guard count >= 0 else { return }
        writes += 1
        bytes += UInt64(count)
        byKind[kind, default: 0] += UInt64(count)
    }

    func sampleRate(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let old = baseline, now > old.time {
            rate = Double(bytes - old.bytes) / (now - old.time)
        } else {
            rate = nil
        }
        baseline = (now, bytes)
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        baseline = nil; rate = nil
    }

    func snapshot() -> FileWriteSummary {
        lock.lock(); defer { lock.unlock() }
        return FileWriteSummary(bytes: bytes, writes: writes, failures: failures,
                                bytesPerSecond: rate, byKind: byKind)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        bytes = 0; writes = 0; failures = 0; byKind = [:]; baseline = nil; rate = nil
    }
}

enum PerfFileWriter {
    /// Preserve Data.write's success/error behavior, and count only completed payloads.
    static func write(_ data: Data, to url: URL, kind: PerfFileKind,
                      tally: FileWriteTally = Perf.shared.fileWrites) throws {
        do {
            try data.write(to: url, options: .atomic)
            tally.record(bytes: data.count, kind: kind, succeeded: true)
        } catch {
            tally.record(bytes: data.count, kind: kind, succeeded: false)
            throw error
        }
    }
}
