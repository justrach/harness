// Crash and hang reports kept from MetricKit (CrashReports): what the list
// says about one, and that each is kept once and only the newest 50 stay.

import XCTest
@testable import Harness

final class CrashReportsTests: XCTestCase {
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testAWatchdogKillReadsAsTheWatchdogSaidIt() {
        let report = json([
            "crashDiagnostics": [[
                "diagnosticMetaData": [
                    "appBuildVersion": "37",
                    "exceptionType": 10,
                    "signal": 9,
                    "terminationReason": "Namespace FRONTBOARD, Code 0x8BADF00D scene-update watchdog transgression\nmore",
                ],
                "callStackTree": ["callStacks": []],
            ]],
            "hangDiagnostics": [["diagnosticMetaData": ["hangDuration": "3.2 sec"]]],
        ])
        let summary = CrashReports.summary(of: report)
        XCTAssertEqual(summary.crashes, 1)
        XCTAssertEqual(summary.hangs, 1)
        XCTAssertEqual(summary.build, "37")
        XCTAssertEqual(summary.headline, "Crash: Namespace FRONTBOARD, Code 0x8BADF00D scene-update watchdog transgression")
    }

    func testOtherReportsSayWhatTheyAre() {
        let crash = json(["crashDiagnostics": [["diagnosticMetaData": ["exceptionType": 1, "signal": 11]]]])
        XCTAssertEqual(CrashReports.summary(of: crash).headline, "Crash: EXC_BAD_ACCESS · SIGSEGV")
        let hang = json(["hangDiagnostics": [["diagnosticMetaData": ["hangDuration": "3.2 sec", "appBuildVersion": "40"]]]])
        XCTAssertEqual(CrashReports.summary(of: hang).headline, "Hang (3.2 sec)")
        XCTAssertEqual(CrashReports.summary(of: hang).build, "40")
        XCTAssertEqual(CrashReports.summary(of: json(["diskWriteExceptionDiagnostics": [[:]]])).headline, "Heavy disk writes")
        XCTAssertEqual(CrashReports.summary(of: Data("not json".utf8)), CrashReports.Summary())
    }

    func testEachReportIsKeptOnceAndOnlyTheNewestStay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = CrashReports()
        let first = json(["hangDiagnostics": [["diagnosticMetaData": ["hangDuration": "1 sec"]]]])
        reports.save([first], in: folder, now: Date(timeIntervalSince1970: 1))
        reports.save([first], in: folder, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(reports.reports(in: folder).count, 1, "iOS can hand a report over twice")
        for i in 0..<(CrashReports.keep + 5) {
            reports.save([json(["hangDiagnostics": [["diagnosticMetaData": ["hangDuration": "\(i) sec"]]]])],
                         in: folder, now: Date(timeIntervalSince1970: Double(10 + i)))
        }
        let kept = reports.reports(in: folder)
        XCTAssertEqual(kept.count, CrashReports.keep)
        XCTAssertEqual(kept.first?.summary.headline, "Hang (\(CrashReports.keep + 4) sec)", "newest first")
    }

    func testUploadsGoInBatchesTheEdgeTakes() {
        let small = (0..<23).map { (id: "r\($0)", data: Data(repeating: 0x20, count: 100)) }
        XCTAssertEqual(CrashReports.batches(small).map(\.count), [10, 10, 3])
        let big = (0..<3).map { (id: "b\($0)", data: Data(repeating: 0x20, count: 400_000)) }
        XCTAssertEqual(CrashReports.batches(big).map(\.count), [2, 1], "about 900 KB a request")
        let huge = [(id: "h", data: Data(repeating: 0x20, count: 2_000_000))] + small.prefix(2)
        XCTAssertEqual(CrashReports.batches(huge).map(\.count), [1, 2], "an oversized report goes alone")
        XCTAssertTrue(CrashReports.batches([]).isEmpty)
    }

    func testTheUploadBodyIsAJSONArrayOfTheReports() throws {
        let body = CrashReports.body([json(["a": 1]), json(["b": 2])])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Int]])
        XCTAssertEqual(parsed, [["a": 1], ["b": 2]])
    }

    func testSentReportsAreRememberedOnlyWhileTheyAreKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = CrashReports()
        reports.save([json(["hangDiagnostics": [[:]]]), json(["crashDiagnostics": [[:]]])], in: folder)
        let ids = reports.reports(in: folder).map(\.id)
        XCTAssertTrue(CrashReports.sentNames(in: folder).isEmpty)
        CrashReports.markSent(Set(ids + ["gone-123.json"]), in: folder)
        XCTAssertEqual(CrashReports.sentNames(in: folder), Set(ids), "a deleted report is forgotten")
        XCTAssertEqual(reports.reports(in: folder).count, 2, "the sent list is not a report")
    }
}
