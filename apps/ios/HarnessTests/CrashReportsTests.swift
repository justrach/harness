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
}
