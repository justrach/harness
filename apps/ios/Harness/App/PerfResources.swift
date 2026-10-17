// Local-only process counters. CPU is process CPU time / monotonic elapsed time:
// 100% means one fully occupied core, not all cores on the device.
import Foundation
import Darwin

struct ProcessResourceSample {
    let uptime: TimeInterval
    let cpuSeconds: Double?
    let footprintBytes: UInt64?

    static func read() -> Self {
        var cpu = timespec()
        let cpuSeconds = clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu) == 0
            ? Double(cpu.tv_sec) + Double(cpu.tv_nsec) / 1e9 : nil
        return Self(uptime: ProcessInfo.processInfo.systemUptime,
                    cpuSeconds: cpuSeconds, footprintBytes: footprint())
    }

    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

struct ResourceSummary {
    let cpuPercent: Double?
    let peakCPUPercent: Double?
    let footprintBytes: UInt64?
    let peakFootprintBytes: UInt64?
}

final class ResourceTally: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: ProcessResourceSample?
    private var cpu: Double?
    private var peakCPU: Double?
    private var footprint: UInt64?
    private var peakFootprint: UInt64?

    func sample(_ next: ProcessResourceSample) {
        lock.lock(); defer { lock.unlock() }
        if let bytes = next.footprintBytes {
            footprint = bytes
            peakFootprint = max(peakFootprint ?? 0, bytes)
        } else {
            footprint = nil
        }
        cpu = nil
        if let old = previous, let start = old.cpuSeconds, let end = next.cpuSeconds,
           next.uptime > old.uptime, end >= start {
            let percent = (end - start) / (next.uptime - old.uptime) * 100
            if percent.isFinite {
                cpu = percent
                peakCPU = max(peakCPU ?? 0, percent)
            }
        }
        previous = next
    }

    /// Never divide across suspension or a period when monitoring was stopped.
    func pause() {
        lock.lock(); defer { lock.unlock() }
        previous = nil
        cpu = nil
    }

    func snapshot() -> ResourceSummary {
        lock.lock(); defer { lock.unlock() }
        return ResourceSummary(cpuPercent: cpu, peakCPUPercent: peakCPU,
                               footprintBytes: footprint, peakFootprintBytes: peakFootprint)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        previous = nil; cpu = nil; peakCPU = nil; footprint = nil; peakFootprint = nil
    }
}

// The same explicit units and unavailable states in Settings and copied reports.
enum PerfFormat {
    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "Not measured"
    }

    static func bytes(_ value: UInt64?) -> String {
        value.map { String(format: "%.2f MiB", Double($0) / 1_048_576) } ?? "Not measured"
    }

    static func rate(_ value: Double?) -> String {
        value.map { String(format: "%.1f KiB/s", $0 / 1024) } ?? "Not measured"
    }
}
