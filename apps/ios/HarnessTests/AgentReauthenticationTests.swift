import Loro
import XCTest
@testable import Harness

@MainActor
private final class LoginTransportStub: AgentLoginTransport {
    var mode: AgentLoginStart.Mode = .hostBrowser
    var url = ""
    var code: String?
    var providers: [AgentReauthProvider] = []
    var cancelled: [String] = []
    var deferStart = false
    var deferPoll = false
    var pollError: Error?
    var startContinuation: CheckedContinuation<AgentLoginStart, Error>?
    var polls: [String: CheckedContinuation<AgentLoginPoll, Error>] = [:]
    var onStart: (() -> Void)?
    var onPoll: (() -> Void)?

    func start(provider: AgentReauthProvider) async throws -> AgentLoginStart {
        providers.append(provider)
        if deferStart {
            return try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                onStart?()
            }
        }
        return AgentLoginStart(loginId: "login-\(providers.count)",
                               url: url, mode: mode, code: code)
    }

    func poll(loginId: String) async throws -> AgentLoginPoll {
        if let pollError { throw pollError }
        if deferPoll {
            return try await withCheckedThrowingContinuation { continuation in
                polls[loginId] = continuation
                onPoll?()
            }
        }
        return AgentLoginPoll(status: .done, message: nil, url: nil)
    }


    func cancel(loginId: String) async { cancelled.append(loginId) }
}

@MainActor
final class AgentReauthenticationTests: XCTestCase {
    private func errorPart(_ reauth: Any? = nil) throws -> MessagePart {
        var json: [String: Any] = ["id": "auth-error", "kind": "error", "message": "Please sign in"]
        if let reauth { json["reauth"] = reauth }
        return try XCTUnwrap(SessionStore.partFrom(.fromJSON(json)))
    }

    func testSyncedErrorsOnlyAllowTheTwoTypedRoutes() throws {
        for raw in [nil, "unknown", "chatgpt", "ChatGPT-new", "codex login", NSNull(), 1,
                    ["provider": "codex"]] as [Any?] {
            guard case .error(let id, let message, let route) = try errorPart(raw) else {
                return XCTFail("plain error must remain visible")
            }
            XCTAssertEqual(id, "auth-error")
            XCTAssertEqual(message, "Please sign in")
            XCTAssertNil(route, "Malformed/unknown metadata must not offer login")
        }
        for provider in [AgentReauthProvider.chatGPTNew, .codex] {
            guard case .error(_, _, let route) = try errorPart(provider.rawValue) else {
                return XCTFail("typed error")
            }
            XCTAssertEqual(route, provider)
        }
    }

    func testAuthMetadataCorrectionInvalidatesStoreCacheAndHostedRowFingerprint() throws {
        let config = AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                               userId: "test", orgId: "test", deviceId: "phone", deviceName: "Phone",
                               devBearer: "test@test")
        let store = SessionStore(chatId: "chat", config: config, offline: true)
        var entry = MessageEntry(id: "reply", role: .assistant, parts: [try errorPart()],
                                 createdAt: 1, deviceId: "host", status: .complete)
        var versions: [UInt64] = []
        for raw in [nil, "chatgpt-new", "codex", "unknown"] as [String?] {
            entry.parts = [try errorPart(raw)]
            store.setEntries([entry])
            let rows = store.transcriptCache.rows(revision: store.revision,
                                                 entries: store.entries, pendingSends: [])
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.id, "reply#auth-error")
            guard case .errorChip(let message, let route) = row.kind else { return XCTFail("error row") }
            XCTAssertEqual(message, "Please sign in")
            XCTAssertEqual(route?.rawValue, ["chatgpt-new", "codex"].contains(raw ?? "") ? raw : nil)
            versions.append(row.version)
        }
        XCTAssertNotEqual(versions[0], versions[1])
        XCTAssertNotEqual(versions[1], versions[2])
        XCTAssertNotEqual(versions[2], versions[3])
        XCTAssertEqual(versions[0], versions[3])
    }

    func testWireModeCompatibilityRejectsUnknownModes() throws {
        let json = #"{"loginId":"login","url":"","mode":"host-browser"}"#
        let start = try JSONDecoder().decode(AgentLoginStart.self, from: Data(json.utf8))
        XCTAssertEqual(start.mode, .hostBrowser)
        XCTAssertTrue(start.url.isEmpty)
        let deviceStart = try JSONDecoder().decode(AgentLoginStart.self, from:
            Data(#"{"loginId":"login","url":"https://auth.openai.com/codex/device","mode":"device-code","code":"ABCD-1234"}"#.utf8))
        XCTAssertEqual(deviceStart.mode, .deviceCode)
        XCTAssertEqual(deviceStart.code, "ABCD-1234")
        XCTAssertThrowsError(try JSONDecoder().decode(AgentLoginStart.self, from:
            Data(#"{"loginId":"login","url":"https://auth.openai.com/authorize","mode":"arbitrary-command"}"#.utf8)))
    }


    func testDesktopLoginUsesRouteSpecificHostContractAndOnlyPollProvesSuccess() async {
        for provider in [AgentReauthProvider.chatGPTNew, .codex] {
            let transport = LoginTransportStub()
            let recovery = AgentReauthentication(transport: transport, pollDelay: {})
            await recovery.run(provider: provider)
            XCTAssertEqual(transport.providers, [provider])
            XCTAssertEqual(provider.startParameters as NSDictionary, provider == .chatGPTNew
                ? ["harness": "graff", "provider": "chatgpt-new", "reauthenticate": true] as NSDictionary
                : ["harness": "codex", "reauthenticate": true, "deviceAuth": true] as NSDictionary)
            XCTAssertEqual(recovery.phase, .done)
            XCTAssertNil(recovery.approval, "desktop fallback must not expose browser URLs/codes")
            recovery.cancel()
            XCTAssertTrue(transport.cancelled.isEmpty, "completed login must not be cancelled/sign out")
        }
    }


    func testRecoveryRejectsUnsupportedPhoneBrowserAndPasteFlows() async {
        for mode in [AgentLoginStart.Mode.browser, .pasteCode] {
            let transport = LoginTransportStub()
            transport.mode = mode
            let recovery = AgentReauthentication(transport: transport, pollDelay: {})
            await recovery.run(provider: .chatGPTNew)
            guard case .failed = recovery.phase else { return XCTFail("unsupported flow must fail closed") }
        }
    }

    func testDismissDuringStartCancelsLateHostLoginWithoutRestoringSheetState() async throws {
        let transport = LoginTransportStub()
        transport.deferStart = true
        let starting = expectation(description: "start dispatched")
        transport.onStart = { starting.fulfill() }
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        let run = Task { await recovery.run(provider: .codex) }
        await fulfillment(of: [starting], timeout: 1)
        recovery.cancel()
        try XCTUnwrap(transport.startContinuation).resume(returning: AgentLoginStart(
            loginId: "late", url: "", mode: .hostBrowser, code: nil))
        await run.value
        XCTAssertEqual(transport.cancelled, ["late"])
        XCTAssertEqual(recovery.phase, .idle)
    }

    func testNewAttemptIgnoresOldPollFailure() async throws {
        let transport = LoginTransportStub()
        transport.deferPoll = true
        transport.mode = .deviceCode
        transport.url = "https://auth.openai.com/codex/device"
        transport.code = "OLD-1234"
        let firstPoll = expectation(description: "first poll")
        transport.onPoll = { firstPoll.fulfill() }
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        let firstRun = Task { await recovery.run(provider: .codex) }
        await fulfillment(of: [firstPoll], timeout: 1)
        XCTAssertEqual(recovery.approval?.code, "OLD-1234")
        transport.deferStart = true
        let secondStart = expectation(description: "second start")
        transport.onStart = { secondStart.fulfill() }
        let secondPoll = expectation(description: "second poll")
        transport.onPoll = { secondPoll.fulfill() }
        let secondRun = Task { await recovery.run(provider: .chatGPTNew) }
        await fulfillment(of: [secondStart], timeout: 1)
        XCTAssertEqual(recovery.phase, .starting)
        XCTAssertNil(recovery.approval, "new attempt clears the old approval immediately")
        try XCTUnwrap(transport.startContinuation).resume(returning: AgentLoginStart(
            loginId: "login-2", url: "", mode: .hostBrowser, code: nil))
        await fulfillment(of: [secondPoll], timeout: 1)
        XCTAssertNil(recovery.approval, "chatgpt-new retains desktop completion")
        try XCTUnwrap(transport.polls.removeValue(forKey: "login-2"))
            .resume(returning: AgentLoginPoll(status: .done, message: nil, url: nil))
        await secondRun.value
        try XCTUnwrap(transport.polls.removeValue(forKey: "login-1")).resume(throwing: RelayError.hostOffline)
        await firstRun.value
        XCTAssertEqual(recovery.phase, .done)
        XCTAssertNil(recovery.approval)
        XCTAssertEqual(transport.providers, [.codex, .chatGPTNew])
        // A new attempt detaches from the earlier one instead of cancelling it: the host may share
        // that approval with another viewer, and a same-route retry attaches to it.
        XCTAssertFalse(transport.cancelled.contains("login-1"))
        XCTAssertFalse(transport.cancelled.contains("login-2"))
    }

    func testOfflineHostShowsRecoveryFailureInsteadOfSignInSuccess() async {
        let transport = LoginTransportStub()
        transport.pollError = RelayError.hostOffline
        transport.mode = .deviceCode
        transport.url = "https://auth.openai.com/codex/device"
        transport.code = "ABCD-1234"
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        await recovery.run(provider: .codex)
        guard case .failed(let message) = recovery.phase else { return XCTFail("host offline must fail") }
        XCTAssertTrue(message.contains("execution device is offline"))
        XCTAssertNil(recovery.approval)
        await Task.yield()
        XCTAssertEqual(transport.cancelled, ["login-1"])
    }

    func testDeviceCodeApprovalRemainsPendingUntilHostReportsDoneAndIgnoresPollURLs() async throws {
        do {
            let transport = LoginTransportStub()
            transport.mode = .deviceCode
            transport.url = "https://auth.openai.com/codex/device"
            transport.code = "ABCD-1234"
            transport.deferPoll = true
            let firstPoll = expectation(description: "approval pending")
            transport.onPoll = { firstPoll.fulfill() }
            let recovery = AgentReauthentication(transport: transport, pollDelay: {})
            let run = Task { await recovery.run(provider: .codex) }
            await fulfillment(of: [firstPoll], timeout: 1)
            XCTAssertEqual(recovery.phase, .waiting)
            XCTAssertEqual(recovery.approval?.url.absoluteString, transport.url)
            XCTAssertEqual(recovery.approval?.code, transport.code)

            let secondPoll = expectation(description: "host remains pending")
            transport.onPoll = { secondPoll.fulfill() }
            try XCTUnwrap(transport.polls.removeValue(forKey: "login-1")).resume(returning:
                AgentLoginPoll(status: .pending, message: "untrusted host output",
                               url: "https://auth.openai.com/oauth/callback?token=not-a-real-token"))
            await fulfillment(of: [secondPoll], timeout: 1)
            XCTAssertEqual(recovery.phase, .waiting, "opening/approving on the phone is not proof of host success")
            XCTAssertEqual(recovery.approval?.url.absoluteString, transport.url)
            XCTAssertEqual(recovery.approval?.code, "ABCD-1234")
            try XCTUnwrap(transport.polls.removeValue(forKey: "login-1")).resume(returning:
                AgentLoginPoll(status: .done, message: nil,
                               url: "https://untrusted.invalid/never-open"))
            await run.value
            XCTAssertEqual(recovery.phase, .done)
            XCTAssertNil(recovery.approval)
            recovery.cancel()
            XCTAssertTrue(transport.cancelled.isEmpty)
        }
    }

    func testChatGPTNewRejectsDeviceCodeEvenWithSafeApprovalDetails() async {
        let transport = LoginTransportStub()
        transport.mode = .deviceCode
        transport.url = "https://auth.openai.com/codex/device"
        transport.code = "ABCD-1234"
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        await recovery.run(provider: .chatGPTNew)
        guard case .failed = recovery.phase else { return XCTFail("chatgpt-new requires host-browser completion") }
        XCTAssertNil(recovery.approval)
        await Task.yield()
        XCTAssertEqual(transport.cancelled, ["login-1"])
    }

    func testDeviceCodeRejectsUnsafeApprovalURLs() async {
        for url in [
            "", "http://auth.openai.com/codex/device", "https://auth.openai.com.evil.invalid/codex/device",
            "https://user:password@auth.openai.com/codex/device", "https://auth.openai.com:443/codex/device",
            "https://auth.openai.com/codex/device?code=ABCD-1234", "https://auth.openai.com/codex/device#token",
            "https://auth.openai.com/codex/device/", "https://auth.openai.com/codex/%64evice",
            "https://AUTH.OPENAI.COM/codex/device", " https://auth.openai.com/codex/device",
            "https://auth.openai.com/api/accounts/authorize?state=test", "javascript:alert(1)"
        ] {
            let transport = LoginTransportStub()
            transport.mode = .deviceCode
            transport.url = url
            transport.code = "ABCD-1234"
            let recovery = AgentReauthentication(transport: transport, pollDelay: {})
            await recovery.run(provider: .codex)
            guard case .failed = recovery.phase else { return XCTFail("unsafe approval URL was accepted: \(url)") }
            XCTAssertNil(recovery.approval)
            await Task.yield()
            XCTAssertEqual(transport.cancelled, ["login-1"])
        }
    }

    func testDeviceCodeRejectsMissingUnboundedOrNonASCIIUserCodes() async {
        for code in [nil, "", "ABCD 1234", "ABCD\n1234", "ABCD_1234", "ABCD?token", "ÄBCD-1234",
                     "ＡBCD-1234", "ABC", String(repeating: "A", count: 33)] as [String?] {
            let transport = LoginTransportStub()
            transport.mode = .deviceCode
            transport.url = "https://auth.openai.com/codex/device"
            transport.code = code
            let recovery = AgentReauthentication(transport: transport, pollDelay: {})
            await recovery.run(provider: .codex)
            guard case .failed = recovery.phase else { return XCTFail("unsafe user code was accepted") }
            XCTAssertNil(recovery.approval)
        }
    }

    func testHostBrowserFallbackRequiresEmptyApprovalDetails() async {
        for (url, code) in [("", nil), ("", ""), ("https://auth.openai.com/codex/device", nil),
                            ("", "ABCD-1234")] as [(String, String?)] {
            let transport = LoginTransportStub()
            transport.url = url
            transport.code = code
            let recovery = AgentReauthentication(transport: transport, pollDelay: {})
            await recovery.run(provider: .chatGPTNew)
            if url.isEmpty && (code == nil || code == "") {
                XCTAssertEqual(recovery.phase, .done)
            } else {
                guard case .failed = recovery.phase else { return XCTFail("fallback must not expose approval details") }
            }
            XCTAssertNil(recovery.approval)
        }
    }

    func testDismissDuringDeviceApprovalClearsCodeAndIgnoresLateSuccess() async throws {
        let transport = LoginTransportStub()
        transport.mode = .deviceCode
        transport.url = "https://auth.openai.com/codex/device"
        transport.code = "ABCD-1234"
        transport.deferPoll = true
        let polling = expectation(description: "poll dispatched")
        transport.onPoll = { polling.fulfill() }
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        let run = Task { await recovery.run(provider: .codex) }
        await fulfillment(of: [polling], timeout: 1)
        XCTAssertNotNil(recovery.approval)
        recovery.cancel()
        XCTAssertNil(recovery.approval)
        try XCTUnwrap(transport.polls.removeValue(forKey: "login-1")).resume(returning:
            AgentLoginPoll(status: .done, message: nil, url: nil))
        await run.value
        XCTAssertEqual(recovery.phase, .idle)
        XCTAssertNil(recovery.approval)
        XCTAssertEqual(transport.cancelled, ["login-1"])
    }

    func testTaskCancellationDuringApprovalDelayClearsPendingCodeAndDetaches() async {
        let transport = LoginTransportStub()
        transport.mode = .deviceCode
        transport.url = "https://auth.openai.com/codex/device"
        transport.code = "ABCD-1234"
        let waiting = expectation(description: "waiting for host approval")
        let recovery = AgentReauthentication(transport: transport, pollDelay: {
            waiting.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        let run = Task { await recovery.run(provider: .codex) }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertNotNil(recovery.approval)
        run.cancel()
        await run.value
        XCTAssertEqual(recovery.phase, .idle)
        XCTAssertNil(recovery.approval)
        await Task.yield()
        // Dismissing the sheet only detaches: the approval keeps waiting on the host.
        XCTAssertEqual(transport.cancelled, [])
    }

    func testDismissDuringStartDetachesAndLeavesTheHostSignInWaiting() async throws {
        let transport = LoginTransportStub()
        transport.deferStart = true
        let starting = expectation(description: "start dispatched")
        transport.onStart = { starting.fulfill() }
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        let run = Task { await recovery.run(provider: .codex) }
        await fulfillment(of: [starting], timeout: 1)
        recovery.detach()
        try XCTUnwrap(transport.startContinuation).resume(returning: AgentLoginStart(
            loginId: "late", url: "", mode: .hostBrowser, code: nil))
        await run.value
        XCTAssertEqual(transport.cancelled, [], "a dismissed sheet never cancels the host's sign-in")
        XCTAssertEqual(recovery.phase, .idle)
    }

    func testReconnectOutcomesResolveRowsAndAllowOneResume() {
        let outcomes = ReauthOutcomes()
        let key = ReauthOutcomes.key(chatId: "chat", rowId: "row")
        XCTAssertFalse(outcomes.claimResume(key), "no Resume before the host verifies the sign-in")
        outcomes.resolve(key)
        XCTAssertTrue(outcomes.claimResume(key))
        XCTAssertFalse(outcomes.claimResume(key), "a second tap sends nothing")
        outcomes.releaseResume(key)
        XCTAssertTrue(outcomes.claimResume(key), "a Resume that failed to send can be retried")
    }

    func testEarlierReconnectRowsAreTheOnesAUserMessageFollows() {
        func row(_ id: String, _ kind: RowKind) -> TranscriptRow {
            TranscriptRow(id: id, version: 0, turnStart: true, kind: kind, entryId: id)
        }
        let rows = [
            row("e1", .errorChip(message: "expired", reauth: .chatGPTNew)),
            row("u1", .user(text: "resume")),
            row("e2", .errorChip(message: "expired", reauth: .chatGPTNew)),
            row("e3", .errorChip(message: "plain", reauth: nil)),
        ]
        XCTAssertEqual(TranscriptView.earlierReauthRows(rows), ["e1"])
    }

    func testHostFailureClearsApprovalWithoutRetainingPollOutput() async throws {
        let transport = LoginTransportStub()
        transport.mode = .deviceCode
        transport.url = "https://auth.openai.com/codex/device"
        transport.code = "ABCD-1234"
        transport.deferPoll = true
        let polling = expectation(description: "poll dispatched")
        transport.onPoll = { polling.fulfill() }
        let recovery = AgentReauthentication(transport: transport, pollDelay: {})
        let run = Task { await recovery.run(provider: .codex) }
        await fulfillment(of: [polling], timeout: 1)
        try XCTUnwrap(transport.polls.removeValue(forKey: "login-1")).resume(returning:
            AgentLoginPoll(status: .error, message: "https://untrusted.invalid/?token=not-a-real-token", url: transport.url))
        await run.value
        XCTAssertEqual(recovery.phase, .failed("Sign-in failed. Try again on the execution device."))
        XCTAssertNil(recovery.approval)
        await Task.yield()
        XCTAssertEqual(transport.cancelled, ["login-1"])
    }

}
