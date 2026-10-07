import XCTest
@testable import Harness

/// What the new-session screen and Settings → Connection say, from store state and registry events.
@MainActor
final class ConnectionStateTests: XCTestCase {
    private var appConfig: AppConfig {
        AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                  userId: "connection-tests", orgId: "tests", deviceId: "ios-test",
                  deviceName: "Test phone", devBearer: "connection-tests@tests")
    }

    private func liveModel() -> (AppModel, WorkspaceStore) {
        let store = WorkspaceStore(config: appConfig, doc: RegistryDoc(deviceId: "ios-test"))
        let model = AppModel()
        model.workspace = store
        return (model, store)
    }

    // MARK: banner

    func testAHostWithNoBeatYetOnAConnectedPhoneGetsNoWarning() {
        let (model, store) = liveModel()
        store.handle(.connected)
        XCTAssertEqual(model.hostStatus("host"), .unknown)
        XCTAssertNil(model.hostNotice(for: "host"), "unconfirmed is not offline")
    }

    func testABeatMakesTheHostOnlineAndClearsAnyNotice() {
        let (model, store) = liveModel()
        store.handle(.connected)
        store.handle(.presence(device: "host", at: 1))
        XCTAssertEqual(model.hostStatus("host"), .online)
        XCTAssertTrue(model.deviceOnline("host"))
        XCTAssertNil(model.hostNotice(for: "host"))
    }

    func testADisconnectedPhoneSaysItIsReconnectingNotThatTheHostIsOffline() {
        let (model, _) = liveModel()
        XCTAssertEqual(model.hostNotice(for: "host"), .reconnecting)
    }

    func testADeadSignInWinsOverEverythingElse() {
        let (model, store) = liveModel()
        store.handle(.connected)
        model.sessionExpired = true
        XCTAssertEqual(model.hostNotice(for: "host"), .signedOut)
        store.handle(.presence(device: "host", at: 1))
        XCTAssertEqual(model.hostNotice(for: "host"), .signedOut, "a live host does not make a dead sign-in fine")
    }

    func testNoWorkspaceMeansNoNotice() {
        XCTAssertNil(AppModel().hostNotice(for: "host"))
    }

    // MARK: report wording

    func testReportSaysWhySignedOutInPlainWords() {
        var report = ConnectionReport(auth: .init(signedIn: true, rejected: true, accessExpiresAt: nil,
                                                  lastRefreshAt: nil, lastRefreshOutcome: "rejected"),
                                      registryConnected: false, registrySynced: true, retryInSeconds: 8,
                                      devices: [])
        XCTAssertEqual(report.signIn, "Signed out — sign in again")
        XCTAssertEqual(report.registry, "Reconnecting in 8s")
        report.auth?.rejected = false
        XCTAssertEqual(report.signIn, "Signed in")
    }

    func testReportTokenExpiryAndLastRefresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let report = ConnectionReport(
            auth: .init(signedIn: true, rejected: false, accessExpiresAt: now.addingTimeInterval(240),
                        lastRefreshAt: now.addingTimeInterval(-90), lastRefreshOutcome: "refreshed"),
            registryConnected: true, registrySynced: true, retryInSeconds: nil, devices: [])
        XCTAssertEqual(report.accessToken(now: now), "Renews in 4 min")
        XCTAssertEqual(report.lastRefresh(now: now), "Refreshed, 1 min ago")
        XCTAssertEqual(report.registry, "Connected")
        XCTAssertEqual(report.accessToken(now: now.addingTimeInterval(300)), "Expired 1 min ago")
    }

    func testReportDeviceLinesAndCopyText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let report = ConnectionReport(
            auth: nil, registryConnected: true, registrySynced: true, retryInSeconds: nil,
            devices: [.init(name: "Desktop", isThisPhone: false, status: .online, beatAgeSeconds: 12),
                      .init(name: "Old box", isThisPhone: false, status: .unknown, beatAgeSeconds: nil),
                      .init(name: "Phone", isThisPhone: true, status: .offline, beatAgeSeconds: 400)])
        XCTAssertEqual(ConnectionReport.deviceLine(report.devices[0]), "Online · last beat 12s ago")
        XCTAssertEqual(ConnectionReport.deviceLine(report.devices[1]), "Not confirmed · no beat yet")
        let text = report.text(now: now)
        XCTAssertTrue(text.contains("Desktop: Online · last beat 12s ago"))
        XCTAssertTrue(text.contains("This phone: Offline · last beat 6 min ago"))
        XCTAssertFalse(text.contains("Phone:"), "this phone is not listed by name")
    }

    func testSpanIsCoarse() {
        XCTAssertEqual(ConnectionReport.span(5), "5s")
        XCTAssertEqual(ConnectionReport.span(59), "59s")
        XCTAssertEqual(ConnectionReport.span(60), "1 min")
        XCTAssertEqual(ConnectionReport.span(3_600), "1 h")
        XCTAssertEqual(ConnectionReport.span(-3), "0s")
    }

    // MARK: sign-in snapshot

    func testExpiryIsReadFromTheTokenAndUnparseableTokensReadAsNil() {
        func jwt(exp: Int) -> String {
            let payload = Data("{\"exp\":\(exp)}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "h.\(payload).s"
        }
        XCTAssertEqual(AppConfig.expiry(ofJWT: jwt(exp: 1_700_000_000)),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(AppConfig.expiry(ofJWT: "not-a-jwt"))
    }

    func testADevSignInIsNeverReportedRejected() {
        let diagnostics = appConfig.authDiagnostics()
        XCTAssertTrue(diagnostics.signedIn)
        XCTAssertFalse(diagnostics.rejected)
        XCTAssertFalse(appConfig.signInRejected)
    }
}
