// Runs the rules the SwiftUI and Compose apps must share against the JSON in apps/parity.
// The Android app runs the same files in ParityTest.kt: the expected values are what this
// app does, so a change on either side that moves them fails a test on the other.

import Loro
import XCTest
@testable import Harness

@MainActor
final class ParityTests: XCTestCase {
    // MARK: Fixtures

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()  // apps/ios
        .deletingLastPathComponent().deletingLastPathComponent()  // repo root

    private static var parity: URL { root.appendingPathComponent("apps/parity") }

    private func load(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.parity.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
    }

    private func rows(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]], key)
    }

    private func strings(_ value: Any?) -> [String] { (value as? [String]) ?? [] }

    private func optionalString(_ value: Any?) -> String? { value as? String }

    // MARK: Message queue (pure rules)

    func testTheImageOnlyTextMatches() throws {
        let queue = try load("vectors/message-queue.json")
        XCTAssertEqual(attachmentOnlyText, queue["attachmentOnlyText"] as? String)
    }

    func testActionsCarryTheSameHostMethodsAndLabels() throws {
        let actions = try XCTUnwrap(try load("vectors/message-queue.json")["actions"] as? [String: [String: String]])
        XCTAssertEqual(QueueAction.sendNow.method, actions["sendNow"]?["method"])
        XCTAssertEqual(QueueAction.sendNow.label, actions["sendNow"]?["label"])
        XCTAssertEqual(QueueAction.remove.method, actions["remove"]?["method"])
        XCTAssertEqual(QueueAction.remove.label, actions["remove"]?["label"])
    }

    func testLabelOneLineAndNeighbour() throws {
        let queue = try load("vectors/message-queue.json")
        for c in try rows(queue, "label") {
            XCTAssertEqual(MessageQueue.label(c["count"] as! Int), optionalString(c["expect"]), "\(c)")
        }
        for c in try rows(queue, "oneLine") {
            XCTAssertEqual(MessageQueue.oneLine(c["text"] as! String), c["expect"] as? String, "\(c)")
        }
        for c in try rows(queue, "neighbour") {
            let got = MessageQueue.neighbour(of: c["from"] as! Int, direction: c["direction"] as! Int, count: c["count"] as! Int)
            XCTAssertEqual(got, c["expect"] as? Int, "\(c)")
        }
    }

    func testEditedAndVisibleText() throws {
        let queue = try load("vectors/message-queue.json")
        for c in try rows(queue, "editedText") {
            XCTAssertEqual(MessageQueue.editedText(c["text"] as! String, hasAttachments: c["hasAttachments"] as! Bool),
                           optionalString(c["expect"]), "\(c)")
        }
        for c in try rows(queue, "visibleText") {
            XCTAssertEqual(MessageQueue.visibleText(c["text"] as! String, attachments: strings(c["attachments"])),
                           c["expect"] as? String, "\(c)")
        }
    }

    private func gate(_ kind: Any?) -> QueueDeliveryGate? {
        switch kind as? String {
        case "reviewRequired": return .reviewRequired(ownerDeviceId: "mac")
        case "editing": return .editing(ownerDeviceId: "mac", expiresAtMs: 60_000)
        default: return nil
        }
    }

    private func action(_ name: Any?) -> QueueAction { (name as? String) == "remove" ? .remove : .sendNow }

    private func reply(_ value: [String: Any]) -> QueueActionReply {
        QueueActionReply(sent: value["sent"] as? Bool, removed: value["removed"] as? Bool)
    }

    func testPrimaryActionAndAcknowledgement() throws {
        let queue = try load("vectors/message-queue.json")
        for c in try rows(queue, "primaryAction") {
            var item = QueuedMessage(id: "q", text: "hello")
            item.attachments = strings(c["attachments"])
            item.deliveryGate = gate(c["gate"])
            let got = MessageQueue.primaryAction(for: item, supportsActions: c["supportsActions"] as! Bool, pending: c["pending"] as! Bool)
            XCTAssertEqual(got, (c["expect"] as? String).map { action($0) }, "\(c)")
        }
        for c in try rows(queue, "acknowledged") {
            XCTAssertEqual(reply(c["reply"] as! [String: Any]).acknowledged(action(c["action"])), c["expect"] as? Bool, "\(c)")
        }
    }

    func testComposerEditRules() throws {
        let queue = try load("vectors/message-queue.json")
        for c in try rows(queue, "composerEdit") {
            let lease = QueueEditLease(rowId: "row", leaseId: "lease", text: c["leaseText"] as! String,
                                       baseTextHash: "hash", expiresAtMs: 60_000)
            let edit = QueueComposerEdit(lease: lease, originalDraft: "draft", hasAttachments: c["hasAttachments"] as! Bool)
            XCTAssertEqual(edit.textToCommit(c["commit"] as! String), optionalString(c["expect"]), "\(c["name"] ?? "")")
        }
        let results: [String: QueueEditFinishResult] = [
            "missing": .missing, "lost": .lost, "finished": .finished, "conflict": .conflict, "unavailable": .unavailable,
        ]
        for c in try rows(queue, "editResults") {
            let lease = QueueEditLease(rowId: "row", leaseId: "lease", text: "queued", baseTextHash: "hash", expiresAtMs: 1)
            var edit = QueueComposerEdit(lease: lease, originalDraft: "draft", hasAttachments: false)
            for name in strings(c["results"]) { edit.receive(try XCTUnwrap(results[name])) }
            XCTAssertEqual(edit.terminal, c["terminal"] as? Bool, "\(c)")
        }
    }

    // MARK: Message queue (the store)

    private func store() -> SessionStore {
        SessionStore(chatId: "chat-1", config: AppConfig(
            edgeURL: URL(string: "https://example.test")!,
            mode: .dev, userId: "u1", orgId: "o1",
            deviceId: "ios-test", deviceName: "Dan’s iPhone",
            devBearer: "cmt_dev_test"))
    }

    private func texts(_ store: SessionStore) -> [String] { store.queue.map(\.text) }

    private func id(of text: String, in store: SessionStore) throws -> String {
        try XCTUnwrap(store.queue.first { $0.text == text }?.id, text)
    }

    func testEnqueueRules() throws {
        let spec = try XCTUnwrap(try load("vectors/message-queue.json")["enqueue"] as? [String: Any])
        let store = store()
        for row in try rows(spec, "rows") {
            let accepted = store.enqueueMessage(text: row["text"] as! String, attachments: strings(row["attachments"])) != nil
            XCTAssertEqual(accepted, row["expectAccepted"] as? Bool, "\(row)")
        }
        XCTAssertEqual(texts(store), strings(spec["expectTexts"]))
        XCTAssertTrue(store.queue.allSatisfy { $0.holdForTurnEnd == (spec["expectHoldForTurnEnd"] as? Bool) })
    }

    func testMoveRules() throws {
        let spec = try XCTUnwrap(try load("vectors/message-queue.json")["moves"] as? [String: Any])
        let store = store()
        for text in strings(spec["texts"]) { store.enqueueMessage(text: text) }
        for step in try rows(spec, "steps") {
            let rowId = try id(of: step["row"] as! String, in: store)
            if (step["op"] as? String) == "by" {
                store.moveQueued(id: rowId, by: step["by"] as! Int)
            } else {
                store.moveQueued(id: rowId, to: step["to"] as! Int)
            }
            XCTAssertEqual(texts(store), strings(step["expect"]), "\(step)")
        }
    }

    private final class Calls { var invoked = false }

    func testHostActionRules() async throws {
        let queue = try load("vectors/message-queue.json")
        for scenario in try rows(queue, "actionScenarios") {
            let name = scenario["name"] as? String ?? ""
            let store = store()
            for text in strings(scenario["texts"]) { store.enqueueMessage(text: text) }
            let target = try id(of: scenario["target"] as! String, in: store)
            if let kind = scenario["gate"] as? String {
                let map = try XCTUnwrap(store.doc.getMovableList(id: "queue").get(index: 0)?.asLoroMap())
                try map.insert(key: "deliveryGate", v: LoroValue.fromJSON([
                    "kind": kind, "ownerDeviceId": "mac", "expiresAtMs": Int64(60_000),
                ]))
                store.doc.commit()
                store.refreshQueue()
            }
            let calls = Calls()
            let throwing = (scenario["reply"] as? String) == "throw"
            let canned = (scenario["reply"] as? [String: Any]).map(reply)
            let ok = await store.performQueueAction(id: target, action: action(scenario["action"])) { _, _ in
                calls.invoked = true
                if throwing { throw RelayError.hostOffline }
                return canned ?? QueueActionReply()
            }
            XCTAssertEqual(ok, scenario["expectOk"] as? Bool, name)
            XCTAssertEqual(texts(store), strings(scenario["expectTexts"]), name)
            XCTAssertEqual(store.queueActionError, optionalString(scenario["expectError"]), name)
            if let expectCalled = scenario["expectCalled"] as? Bool { XCTAssertEqual(calls.invoked, expectCalled, name) }
            XCTAssertTrue(store.queueActionsPending.isEmpty, name)
        }
    }

    func testAnInFlightActionBlocksCompetingOnes() async throws {
        let spec = try XCTUnwrap(try load("vectors/message-queue.json")["inFlight"] as? [String: Any])
        let store = store()
        for text in strings(spec["texts"]) { store.enqueueMessage(text: text) }
        let target = try id(of: spec["target"] as! String, in: store)
        let before = texts(store)
        let ok = await store.performQueueAction(id: target, action: .remove) { method, _ in
            XCTAssertEqual(method, spec["expectMethod"] as? String)
            XCTAssertEqual(self.texts(store), self.strings(spec["expectTextsDuringCall"]))
            XCTAssertEqual(store.queueActionsPending.contains(target), spec["expectPendingDuringCall"] as? Bool)
            store.moveQueued(id: target, to: 1)
            XCTAssertEqual(self.texts(store), before, "a row with an action in flight must not move")
            let competing = await store.performQueueAction(id: target, action: .sendNow) { _, _ in
                XCTFail("an in-flight action must prevent a competing one")
                return QueueActionReply(sent: true)
            }
            XCTAssertFalse(competing)
            return QueueActionReply(removed: true)
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(texts(store), strings(spec["expectTextsAfter"]))
    }

    // MARK: Account deletion

    func testAccountDeletionAnswers() throws {
        let vectors = try load("vectors/account-deletion.json")
        for c in try rows(vectors, "cases") {
            let name = c["name"] as? String ?? ""
            let outcome = AccountDeletion(status: c["status"] as! Int, data: Data((c["body"] as! String).utf8))
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            switch outcome {
            case .deleted:
                XCTAssertEqual(expect["kind"] as? String, "deleted", name)
            case .refused(let message, let tokens):
                XCTAssertEqual(expect["kind"] as? String, "refused", name)
                XCTAssertEqual(message, expect["message"] as? String, name)
                let expected = expect["tokens"] as? [String: String]
                XCTAssertEqual(tokens?.accessToken, expected?["accessToken"], name)
                XCTAssertEqual(tokens?.refreshToken, expected?["refreshToken"], name)
            }
        }
    }

    // MARK: Home grouping

    private func chat(_ id: String, space: String?, device: String) -> Chat {
        Chat(id: id, deviceId: device, title: id, archived: false, cwd: nil, branch: nil,
             checkoutId: nil, config: nil, lastMessagePreview: nil, lastMessageAt: nil,
             createdAt: 0, spaceId: space, lastSeenAt: nil)
    }

    func testHomeGroupingMatches() throws {
        let vectors = try load("vectors/home-grouping.json")
        let chats = try rows(vectors, "chats").map {
            chat($0["id"] as! String, space: $0["spaceId"] as? String, device: $0["deviceId"] as! String)
        }
        for c in try rows(vectors, "cases") {
            let name = c["name"] as? String ?? ""
            let by = HomeGroupBy(rawValue: c["by"] as! String)!
            let groups = HomeGrouping.groups(chats, by: by, pinned: Set(strings(c["pinned"])))
            let got: [[String: Any]] = groups.map { group in
                let kind: String
                switch group.kind {
                case .all: kind = "all"
                case .pinned: kind = "pinned"
                case .project: kind = "project"
                case .device: kind = "device"
                }
                return ["id": group.id, "kind": kind, "chats": group.chats.map(\.id)]
            }
            let expected = try rows(c, "expect")
            XCTAssertEqual(got.map { $0["id"] as! String }, expected.map { $0["id"] as! String }, name)
            XCTAssertEqual(got.map { $0["kind"] as! String }, expected.map { $0["kind"] as! String }, name)
            XCTAssertEqual(got.map { $0["chats"] as! [String] }, expected.map { strings($0["chats"]) }, name)
        }
    }

    // MARK: UX contract

    private func sources(under directory: String, ext: String) throws -> String {
        let base = Self.root.appendingPathComponent(directory)
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        var text = ""
        for case let url as URL in walker where url.pathExtension == ext {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
    }

    func testEveryContractStringIsInTheSwiftSource() throws {
        let contract = try load("ux-contract.json")
        let source = try sources(under: "apps/ios/Harness", ext: "swift")
        let groups = try XCTUnwrap(contract["strings"] as? [String: [String]])
        for (group, list) in groups {
            for value in list {
                XCTAssertTrue(source.contains("\"\(value)\""), "\(group): \"\(value)\" is missing from the SwiftUI app")
            }
        }
    }

    func testTheQueuePanelIsLaidOutWithTheContractNumbers() throws {
        let layout = try XCTUnwrap(try load("ux-contract.json")["queuePanelLayout"] as? [String: Any])
        let file = try XCTUnwrap(layout["swiftSource"] as? String)
        let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
        let row = layout["rowHeightDp"] as! Int, gap = layout["rowGapDp"] as! Int
        let visible = layout["maxVisibleRows"] as! Int, control = layout["controlSizeDp"] as! Int
        let pad = layout["horizontalPaddingDp"] as! Int
        for snippet in [
            "CGFloat(min(queue.count, \(visible))) * \(row) + CGFloat(max(0, min(queue.count, \(visible)) - 1)) * \(gap)",
            ".frame(width: \(control), height: \(control))",
            ".padding(.horizontal, \(pad))",
        ] {
            XCTAssertTrue(source.contains(snippet), "QueuePanelView no longer contains `\(snippet)`")
        }
    }

    // MARK: Performance monitor

    func testTheMonitorTimesTheSameOperationsAgainstTheSameBudgets() throws {
        let spans = try XCTUnwrap(try load("perf-contract.json")["spans"] as? [String: Double])
        XCTAssertEqual(spans, PerfSpan.budgetsMs)
    }

    private func stats() throws -> [String: Any] { try load("vectors/perf-stats.json") }

    func testTheBucketBoundsAndMetricNamesAreTheSharedOnes() throws {
        let v = try stats()
        XCTAssertEqual(v["bucketsMs"] as? [Double], PerfHistograms.bucketsMs)
        XCTAssertEqual(v["metricOrder"] as? [String], PerfMetric.order)
        XCTAssertEqual(v["schema"] as? String, PerfStatsBatch.schema)
        XCTAssertEqual(v["maxSampleMs"] as? Double, PerfHistograms.maxSampleMs)
        XCTAssertEqual(v["maxDeviceLength"] as? Int, PerfStatsBatch.maxDeviceLength)
        XCTAssertEqual(v["maxVersionLength"] as? Int, PerfStatsBatch.maxVersionLength)
        XCTAssertEqual(v["maxWindowMs"] as? Int, PerfHistograms.maxWindowMs)
        let hz = try XCTUnwrap(v["refreshHz"] as? [String: Int])
        XCTAssertEqual(hz["min"], PerfStatsBatch.refreshHzRange.lowerBound)
        XCTAssertEqual(hz["max"], PerfStatsBatch.refreshHzRange.upperBound)
        XCTAssertEqual(v["minIntervalMs"] as? Int, PerfUploader.minIntervalMs)
        XCTAssertEqual(v["iosSharingDefault"] as? Bool, PerfSharing.defaultEnabled)
        XCTAssertEqual(v["endpoint"] as? String, PerfSharing.endpoint)
        XCTAssertTrue(PerfTransport.isAllowed(try XCTUnwrap(v["endpoint"] as? String)))
        let wire = try XCTUnwrap(try load("perf-contract.json")["wire"] as? [String: String])
        XCTAssertEqual(wire, PerfMetric.forSpan)
    }

    private func meta(_ i: [String: Any]) -> PerfBatchMeta {
        PerfBatchMeta(installId: i["installId"] as! String, os: i["os"] as! String, arch: i["arch"] as! String,
                      appVersion: i["appVersion"] as! String, osVersion: i["osVersion"] as! String,
                      device: i["device"] as! String, refreshHz: i["refreshHz"] as! Int)
    }

    func testABatchIsBuiltTheSameWayOnBothApps() throws {
        for c in try rows(try stats(), "batches") {
            let i = try XCTUnwrap(c["input"] as? [String: Any])
            let clock = Box(i["windowStartMs"] as! Int)
            let histograms = PerfHistograms(now: { clock.value })
            let samples = try XCTUnwrap(i["samples"] as? [String: [Double]])
            for (name, xs) in samples { for x in xs { histograms.add(name, ms: x) } }
            clock.value = i["windowEndMs"] as! Int
            let window = histograms.take() ?? PerfWindow(startMs: i["windowStartMs"] as! Int, endMs: clock.value, metrics: [])
            let json = PerfStatsBatch(meta: meta(i), window: window).json()
            let expected = try XCTUnwrap(c["expect"] as? [String: Any])
            XCTAssertTrue((expected as NSDictionary).isEqual(json), "\(c["name"] ?? "")\nexpected \(expected)\ngot \(json)")
        }
    }

    func testTheUploaderSendsWhenTheSharedRulesSay() async throws {
        for c in try rows(try stats(), "uploader") {
            let config = try XCTUnwrap(c["config"] as? [String: Any])
            let clock = Box(0), status = Box(204), posts = Box(0)
            let enabled = config["enabled"] as! Bool
            let histograms = PerfHistograms(now: { clock.value })
            let uploader = PerfUploader(endpoint: config["endpoint"] as? String, enabled: { enabled }, source: histograms,
                                        now: { clock.value }, post: { _, _ in posts.value += 1; return status.value })
            let meta = PerfBatchMeta(installId: "id", os: "ios", arch: "aarch64", appVersion: "1", osVersion: "27",
                                     device: "iPhone", refreshHz: 120)
            for step in try rows(c, "steps") {
                clock.value = step["atMs"] as! Int
                status.value = step["status"] as! Int
                for _ in 0..<(step["addSamples"] as! Int) { histograms.add(PerfMetric.appLaunch, ms: 5) }
                let before = posts.value
                let sent = await uploader.flush(meta: meta)
                let label = "\(c["name"] ?? "") at \(clock.value)ms"
                XCTAssertEqual(sent, step["expectSent"] as? Bool, label)
                XCTAssertEqual(posts.value > before, step["expectPosted"] as? Bool, "\(label): posted")
                XCTAssertEqual(histograms.pendingSamples, step["expectPending"] as? Int, "\(label): samples held")
            }
        }
    }

    func testBackgroundWorkHoldsBackWhenTheDeviceIsHotOrSavingPower() throws {
        for c in try rows(try stats(), "deviceCalm") {
            XCTAssertEqual(PerfPolicy.deviceIsCalm(lowPower: c["lowPower"] as! Bool, thermal: c["thermal"] as! String),
                           c["expect"] as? Bool, "\(c)")
        }
    }

    // MARK: Bring in your agent

    private func deviceAgents(_ d: [String: Any]) -> DeviceAgents {
        let agents = (d["agents"] as! [[String: Any]]).map { a in
            AgentDescriptor(id: a["id"] as! String, installed: a["installed"] as? Bool ?? true,
                            canInstall: a["canInstall"] as? Bool ?? false, enabled: a["enabled"] as? Bool)
        }
        return DeviceAgents(id: d["id"] as! String, name: d["name"] as! String, online: d["online"] as! Bool, agents: agents)
    }

    func testTheAgentReadinessRulesMatch() throws {
        let v = try load("vectors/agent-readiness.json")
        XCTAssertEqual(v["agents"] as? [String], OnboardingAgent.all.map(\.id))
        XCTAssertEqual(v["downloadUrl"] as? String, AgentReadiness.downloadURL)
        for c in try rows(v, "cases") {
            let devices = (c["devices"] as! [[String: Any]]).map(deviceAgents)
            let report = AgentReadiness.evaluate(devices)
            let expected = try XCTUnwrap(c["expect"] as? [String: Any])
            let name = "\(c["name"] ?? "")"
            XCTAssertEqual(report.state.rawValue, expected["state"] as? String, name)
            let rows = try XCTUnwrap(expected["agents"] as? [[String: Any]])
            XCTAssertEqual(report.rows.map(\.agent.id), rows.map { $0["id"] as! String }, name)
            XCTAssertEqual(report.rows.map(\.status.wireName), rows.map { $0["status"] as! String }, name)
            XCTAssertEqual(report.rows.map(\.deviceIds), rows.map { $0["devices"] as! [String] }, name)
        }
    }

    /// Test double for a value the uploader's `@Sendable` closures read while the test moves it on.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    func testOnlyHttpsOrLoopbackIsAnAllowedEndpoint() {
        XCTAssertTrue(PerfTransport.isAllowed("https://example.invalid/perf"))
        XCTAssertTrue(PerfTransport.isAllowed("http://127.0.0.1:8080/perf"))
        XCTAssertFalse(PerfTransport.isAllowed("http://example.invalid/perf"))
        XCTAssertFalse(PerfTransport.isAllowed("ftp://example.invalid/perf"))
        XCTAssertFalse(PerfTransport.isAllowed("not a url"))
    }

    func testThePerformancePageUsesTheContractStrings() throws {
        let contract = try load("perf-contract.json")
        var strings = try XCTUnwrap(contract["strings"] as? [String: String])
        strings.merge(contract["iosStrings"] as? [String: String] ?? [:]) { _, ios in ios }
        let source = try sources(under: "apps/ios/Harness", ext: "swift")
        for value in strings.values {
            XCTAssertTrue(source.contains("\"\(value)\""), "\(value) is missing from the SwiftUI app")
        }
    }
}
