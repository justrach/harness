import XCTest
@testable import Harness

@MainActor
final class LivePerfTests: XCTestCase {
    func testCPUUsesElapsedProcessTimeAndMayExceedOneCore() {
        let tally = ResourceTally()
        tally.sample(ProcessResourceSample(uptime: 10, cpuSeconds: 2, footprintBytes: 100))
        XCTAssertNil(tally.snapshot().cpuPercent, "one reading is only a baseline")
        tally.sample(ProcessResourceSample(uptime: 12, cpuSeconds: 6, footprintBytes: 80))
        XCTAssertEqual(tally.snapshot().cpuPercent, 200)
        XCTAssertEqual(tally.snapshot().peakCPUPercent, 200)
        XCTAssertEqual(tally.snapshot().footprintBytes, 80)
        XCTAssertEqual(tally.snapshot().peakFootprintBytes, 100)
        tally.sample(ProcessResourceSample(uptime: 14, cpuSeconds: 7, footprintBytes: 90))
        XCTAssertEqual(tally.snapshot().cpuPercent, 50)
        XCTAssertEqual(tally.snapshot().peakCPUPercent, 200)
    }

    func testCPUDoesNotAverageAcrossSuspensionOrMissingSamples() {
        let tally = ResourceTally()
        tally.sample(ProcessResourceSample(uptime: 1, cpuSeconds: 1, footprintBytes: 100))
        tally.pause()
        tally.sample(ProcessResourceSample(uptime: 1000, cpuSeconds: 20, footprintBytes: nil))
        XCTAssertNil(tally.snapshot().cpuPercent)
        XCTAssertNil(tally.snapshot().footprintBytes, "unavailable must not be reported as zero")
        tally.sample(ProcessResourceSample(uptime: 1001, cpuSeconds: nil, footprintBytes: 200))
        XCTAssertNil(tally.snapshot().cpuPercent)
        tally.sample(ProcessResourceSample(uptime: 1002, cpuSeconds: 21, footprintBytes: 200))
        XCTAssertNil(tally.snapshot().cpuPercent)
        tally.sample(ProcessResourceSample(uptime: 1003, cpuSeconds: 21.5, footprintBytes: 200))
        XCTAssertEqual(tally.snapshot().cpuPercent, 50)
    }

    func testInvalidResourceDeltasAndReset() {
        let tally = ResourceTally()
        tally.sample(ProcessResourceSample(uptime: 2, cpuSeconds: 4, footprintBytes: 100))
        tally.sample(ProcessResourceSample(uptime: 2, cpuSeconds: 5, footprintBytes: 100))
        XCTAssertNil(tally.snapshot().cpuPercent)
        tally.sample(ProcessResourceSample(uptime: 3, cpuSeconds: 1, footprintBytes: 100))
        XCTAssertNil(tally.snapshot().cpuPercent)
        tally.reset()
        XCTAssertNil(tally.snapshot().peakCPUPercent)
        XCTAssertNil(tally.snapshot().peakFootprintBytes)
    }

    func testProcessCountersAreAvailableOnTheTestDevice() throws {
        let sample = ProcessResourceSample.read()
        XCTAssertGreaterThan(sample.uptime, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.cpuSeconds), 0)
        XCTAssertGreaterThan(try XCTUnwrap(sample.footprintBytes), 0)
    }

    func testTrackedWritesCountRewritesNotJustFileGrowthAndKeepFailuresSeparate() throws {
        let tally = FileWriteTally()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache")
        try PerfFileWriter.write(Data(repeating: 1, count: 100), to: url, kind: .snapshots, tally: tally)
        try PerfFileWriter.write(Data(repeating: 2, count: 80), to: url, kind: .snapshots, tally: tally)
        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 2, count: 80))
        XCTAssertThrowsError(try PerfFileWriter.write(Data(repeating: 3, count: 99),
            to: directory.appendingPathComponent("absent/file"), kind: .attachments, tally: tally))
        let result = tally.snapshot()
        XCTAssertEqual(result.bytes, 180)
        XCTAssertEqual(result.writes, 2)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(result.byKind[.snapshots], 180)
        XCTAssertNil(result.byKind[.attachments])
    }

    func testWriteRateExcludesUnobservedTimeAndResetHasNoNegativeDelta() {
        let tally = FileWriteTally()
        tally.sampleRate(at: 1)
        tally.record(bytes: 2048, kind: .registry, succeeded: true)
        tally.sampleRate(at: 3)
        XCTAssertEqual(tally.snapshot().bytesPerSecond, 1024)
        tally.pause()
        tally.record(bytes: 100, kind: .models, succeeded: true)
        tally.sampleRate(at: 1000)
        XCTAssertNil(tally.snapshot().bytesPerSecond)
        tally.reset()
        tally.sampleRate(at: 1001)
        XCTAssertNil(tally.snapshot().bytesPerSecond)
        XCTAssertEqual(tally.snapshot().bytes, 0)
        XCTAssertTrue(tally.snapshot().byKind.isEmpty)
    }

    func testCadenceCountsGapsAtTheActualRefreshInterval() throws {
        let cadence = CadenceTally()
        cadence.setActive(.scrolling, true)
        cadence.record(timestamp: 1, expectedInterval: 1.0 / 60)
        cadence.record(timestamp: 1 + 1.0 / 60, expectedInterval: 1.0 / 60)
        cadence.record(timestamp: 1 + 4.0 / 60, expectedInterval: 1.0 / 60)
        let result = cadence.snapshot(.scrolling)
        XCTAssertEqual(result.intervals, 2)
        XCTAssertEqual(result.missedRefreshes, 2)
        XCTAssertEqual(try XCTUnwrap(result.averageHz), 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.p95Ms), 50, accuracy: 0.001)
        XCTAssertEqual(cadence.snapshot(.streaming).intervals, 0)
    }

    func testCadenceRespectsRefreshRateChangesAndPauses() {
        let cadence = CadenceTally()
        cadence.setActive(.streaming, true)
        cadence.record(timestamp: 1, expectedInterval: 1.0 / 120)
        cadence.record(timestamp: 1 + 1.0 / 120, expectedInterval: 1.0 / 120)
        cadence.record(timestamp: 1 + 3.0 / 120, expectedInterval: 1.0 / 60)
        XCTAssertEqual(cadence.snapshot(.streaming).missedRefreshes, 0)
        cadence.setActive(.streaming, false)
        cadence.record(timestamp: 900, expectedInterval: 1.0 / 60)
        cadence.setActive(.streaming, true)
        cadence.record(timestamp: 1000, expectedInterval: 1.0 / 60)
        XCTAssertEqual(cadence.snapshot(.streaming).intervals, 2, "idle time is not a giant frame gap")
        cadence.reset()
        cadence.record(timestamp: 1001, expectedInterval: 1.0 / 60)
        cadence.record(timestamp: 1001 + 1.0 / 60, expectedInterval: 1.0 / 60)
        XCTAssertEqual(cadence.snapshot(.streaming).intervals, 1, "reset keeps the active interest")
        XCTAssertEqual(cadence.snapshot(.streaming).missedRefreshes, 0)
    }

    func testCadenceRejectsInvalidSamples() {
        let cadence = CadenceTally()
        cadence.setActive(.scrolling, true)
        cadence.record(timestamp: .nan, expectedInterval: 1.0 / 60)
        cadence.record(timestamp: 1, expectedInterval: 0)
        cadence.record(timestamp: 1, expectedInterval: .infinity)
        XCTAssertEqual(cadence.snapshot(.scrolling).intervals, 0)
        XCTAssertNil(cadence.snapshot(.scrolling).averageHz)
    }

    func testMonitoringOnlyRunsForVisibleInterestsAndPausesInBackground() {
        let monitor = PerfLiveMonitor()
        let page = UUID()
        XCTAssertFalse(monitor.isSampling)
        monitor.setBackgrounded(false)
        monitor.inspect(page, visible: true)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertFalse(monitor.isMeasuringCadence, "Settings must not create display-link load")
        monitor.setBackgrounded(true)
        XCTAssertFalse(monitor.isSampling)
        monitor.setBackgrounded(false)
        XCTAssertTrue(monitor.isSampling)
        monitor.remove(page)
        XCTAssertFalse(monitor.isSampling)
    }

    func testMultipleTranscriptInterestsStopOnlyWhenAllAreQuiet() {
        let monitor = PerfLiveMonitor()
        let scrolling = UUID(), streaming = UUID()
        monitor.setBackgrounded(false)
        monitor.transcript(scrolling, visible: true, scrolling: true, streaming: false)
        monitor.transcript(streaming, visible: true, scrolling: false, streaming: true)
        XCTAssertTrue(monitor.isMeasuringCadence)
        monitor.remove(scrolling)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertTrue(monitor.isMeasuringCadence)
        monitor.setBackgrounded(true)
        XCTAssertFalse(monitor.isMeasuringCadence)
        monitor.setBackgrounded(false)
        XCTAssertTrue(monitor.isMeasuringCadence)
        monitor.transcript(streaming, visible: false, scrolling: false, streaming: true)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertFalse(monitor.isMeasuringCadence)
    }

    func testReportAndResetIncludeNewCountersWithoutUploadingThem() {
        let perf = Perf()
        perf.resources.sample(ProcessResourceSample(uptime: 1, cpuSeconds: 1, footprintBytes: 1_048_576))
        perf.resources.sample(ProcessResourceSample(uptime: 2, cpuSeconds: 1.5, footprintBytes: 2_097_152))
        perf.fileWrites.record(bytes: 1024, kind: .snapshots, succeeded: true)
        perf.cadence.setActive(.scrolling, true)
        perf.cadence.record(timestamp: 1, expectedInterval: 1.0 / 60)
        perf.cadence.record(timestamp: 1 + 1.0 / 60, expectedInterval: 1.0 / 60)
        let report = perf.report(version: "test")
        XCTAssertTrue(report.contains("CPU: 50.0%"))
        XCTAssertTrue(report.contains("2.00 MiB"))
        XCTAssertTrue(report.contains("Tracked file writes:"))
        XCTAssertTrue(report.contains("Scrolling callback cadence:"))
        XCTAssertTrue(report.contains("not GPU FPS"))
        XCTAssertTrue(report.contains("not included in anonymous uploads"))
        XCTAssertEqual(perf.histograms.pendingSamples, 0)
        perf.reset()
        XCTAssertNil(perf.resources.snapshot().peakFootprintBytes)
        XCTAssertEqual(perf.fileWrites.snapshot().writes, 0)
        XCTAssertEqual(perf.cadence.snapshot(.scrolling).intervals, 0)
    }
}
