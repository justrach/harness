import XCTest
@testable import Harness

final class PerfMonitorTests: XCTestCase {
    func testPercentilesUseNearestRank() {
        let r = PerfRecorder()
        for i in 1...100 { r.record("op", ms: Double(i)) }
        let s = r.stats()[0]
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.p50, 50)
        XCTAssertEqual(s.p95, 95)
        XCTAssertEqual(s.max, 100)
    }

    func testWindowKeepsOnlyTheLatestRunsButCountsAll() {
        let r = PerfRecorder(capacity: 4)
        for ms in [100.0, 1, 2, 3, 4] { r.record("op", ms: ms) }
        let s = r.stats()[0]
        XCTAssertEqual(s.count, 5)
        // The 100 fell out of the window, so it no longer lifts the 95th; it stays in max and total.
        XCTAssertEqual(s.p95, 4)
        XCTAssertEqual(s.max, 100)
        XCTAssertEqual(s.totalMs, 110)
    }

    func testOverBudgetRunsAreCounted() {
        let r = PerfRecorder()
        r.record("op", ms: 3, budgetMs: 4)
        r.record("op", ms: 9, budgetMs: 4)
        r.record("op", ms: 4, budgetMs: 4)
        XCTAssertEqual(r.stats()[0].overBudget, 1)
    }

    func testCostliestOperationComesFirst() {
        let r = PerfRecorder()
        r.record("cheap", ms: 1)
        r.record("costly", ms: 50)
        XCTAssertEqual(r.stats().map(\.name), ["costly", "cheap"])
    }

    func testEmptyRecorderHasNoStats() {
        XCTAssertTrue(PerfRecorder().stats().isEmpty)
        XCTAssertEqual(PerfRecorder.percentile([], 0.5), 0)
    }

    func testResetClears() {
        let r = PerfRecorder()
        r.record("op", ms: 1)
        r.reset()
        XCTAssertTrue(r.stats().isEmpty)
    }

    func testSlowAndFrozenTurnsAreCountedSeparately() {
        let t = MainThreadTally()
        for ms in [2.0, 5, 24, 800] { t.add(ms: ms) }
        let s = t.snapshot()
        XCTAssertEqual(s.turns, 4)
        XCTAssertEqual(s.slow, 2)
        XCTAssertEqual(s.frozen, 1)
        XCTAssertEqual(s.slowPercent, 50)
    }

    /// A turn that straddles a suspension measures the time the app was frozen, not what it did. It ends
    /// after the app resumes but before the foreground notification, so it must be dropped while backgrounded.
    func testATurnThatEndsWhileBackgroundedIsNotCountedAsAStall() {
        let perf = Perf()
        perf.turnEnded(ms: 5)
        perf.setBackgrounded(true)
        perf.turnEnded(ms: 240_000)  // the app was frozen mid-turn for minutes
        perf.setBackgrounded(false)
        perf.turnEnded(ms: 60)

        let summary = perf.turns.snapshot()
        XCTAssertEqual(summary.turns, 2, "only the two foreground turns count")
        XCTAssertEqual(summary.worst, 60)
        XCTAssertEqual(summary.frozen, 0)
        let stalls = perf.recorder.stats().first { $0.name == PerfSpan.mainStall }
        XCTAssertEqual(stalls?.count, 1)
        XCTAssertEqual(stalls?.max, 60)
    }

    func testForegroundTurnsAreCountedAsBefore() {
        let perf = Perf()
        for ms in [2.0, 5, 24, 800] { perf.turnEnded(ms: ms) }
        let summary = perf.turns.snapshot()
        XCTAssertEqual(summary.turns, 4)
        XCTAssertEqual(summary.frozen, 1)
        XCTAssertEqual(perf.recorder.stats().first { $0.name == PerfSpan.mainStall }?.count, 1)
    }

    /// Answers every request with a fixed status and remembers what it was sent.
    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var status = 204
        nonisolated(unsafe) static var seen: (method: String?, headers: [String: String], body: String)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
            }
            Self.seen = (request.httpMethod, request.allHTTPHeaderFields ?? [:], String(decoding: data, as: UTF8.self))
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testAReportIsPostedAsPlainJsonWithNoCredentials() async {
        StubProtocol.status = 204
        StubProtocol.seen = nil
        let ok = await PerfTransport.post("https://example.invalid/perf", "{\"schema\":1}") { $0.protocolClasses = [StubProtocol.self] }
        XCTAssertEqual(ok, 204)
        XCTAssertEqual(StubProtocol.seen?.method, "POST")
        XCTAssertEqual(StubProtocol.seen?.body, "{\"schema\":1}")
        XCTAssertEqual(StubProtocol.seen?.headers["Content-Type"], "application/json")
        for name in ["Authorization", "Cookie"] {
            XCTAssertNil(StubProtocol.seen?.headers[name], "\(name) was sent")
        }
        StubProtocol.status = 500
        let failed = await PerfTransport.post("https://example.invalid/perf", "{}") { $0.protocolClasses = [StubProtocol.self] }
        XCTAssertEqual(failed, 500)
        let refused = await PerfTransport.post("http://example.invalid/perf", "{}") { $0.protocolClasses = [StubProtocol.self] }
        XCTAssertEqual(refused, 0, "plain http to a real host must not be sent")
    }

    func testSharingIsOnUntilThePersonTurnsItOffAndStaysOff() {
        let key = PerfSharing.key
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(PerfSharing.enabled, "a never-chosen setting reads as on")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(PerfSharing.enabled, "an explicit off must stay off")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(PerfSharing.enabled)
    }

    /// The monitor sits on hot paths (every run loop turn, every parse), so its per-call cost has a ceiling.
    /// Generous for a debug build; it exists to catch a hundredfold regression, not to benchmark.
    func testRecordingCostsMicroseconds() {
        let n = 100_000
        for _ in 0..<10_000 { _ = Perf.measure(PerfSpan.homeGroup) { 1 } }
        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { _ = Perf.measure(PerfSpan.homeGroup) { 1 } }
        let perCallUs = (CFAbsoluteTimeGetCurrent() - start) * 1e6 / Double(n)
        XCTAssertLessThan(perCallUs, 25, "measure() took \(perCallUs) µs a call")

        let tally = MainThreadTally()
        let histograms = PerfHistograms()
        for _ in 0..<10_000 { tally.add(ms: 3); histograms.add(PerfMetric.mainTurn, ms: 3) }
        start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { tally.add(ms: 3); histograms.add(PerfMetric.mainTurn, ms: 3) }
        let perTurnUs = (CFAbsoluteTimeGetCurrent() - start) * 1e6 / Double(n)
        XCTAssertLessThan(perTurnUs, 25, "a turn took \(perTurnUs) µs to tally")
    }

    func testTheProcessStartTimeIsKnownAndInThePast() throws {
        let start = try XCTUnwrap(Perf.processStart())
        let age = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(age, 0)
        XCTAssertLessThan(age, 3600)
    }

    func testMeasureRecordsUnderTheOperationName() {
        Perf.shared.reset()
        let value = Perf.measure(PerfSpan.homeGroup) { 21 * 2 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(Perf.shared.recorder.stats().first { $0.name == PerfSpan.homeGroup }?.count, 1)
    }

    func testAnInteractionRecordsOnceWhenItFinishes() {
        Perf.shared.reset()
        Perf.shared.startInteraction(PerfSpan.navigationOpen)
        Perf.shared.finishInteraction(PerfSpan.navigationOpen)
        Perf.shared.finishInteraction(PerfSpan.navigationOpen)  // no second start, so nothing more to record
        let done = expectation(description: "recorded")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(Perf.shared.recorder.stats().first { $0.name == PerfSpan.navigationOpen }?.count, 1)
    }
}
