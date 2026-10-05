import Loro
import XCTest
@testable import Harness

@MainActor
final class SessionRenameTests: XCTestCase {
    private var config: AppConfig {
        AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                  userId: "rename-tests", orgId: "tests", deviceId: "ios-test",
                  deviceName: "Test phone")
    }

    private func workspace() -> (AppModel, RegistryDoc) {
        let doc = RegistryDoc(deviceId: config.deviceId)
        doc.applyState(seq: 1, full: true, gcFloor: 0, rows: [
            RegistryRow(kind: "chats", id: "chat-a", seq: 1, deleted: false, delHlc: nil,
                        fields: ["deviceId": .string("host"), "title": .string("Original"),
                                 "archived": .bool(false), "createdAt": .int(1), "roomGen": .int(2)],
                        clocks: [:])
        ])
        let model = AppModel()
        model.workspace = WorkspaceStore(config: config, doc: doc)
        return (model, doc)
    }

    func testRenameUpdatesImmediatelyAndSurvivesOfflineReloadWithItsSyncOutbox() throws {
        let (model, doc) = workspace()
        model.rename(chatId: "chat-a", title: "  Release plan 📝  \n")
        XCTAssertEqual(model.chat(id: "chat-a")?.displayTitle, "Release plan 📝")
        XCTAssertEqual(doc.pending.last?.ops.last?.set?["title"], .string("Release plan 📝"))

        let restoredDoc = try RegistryDoc.from(data: doc.toData(), deviceId: config.deviceId)
        let restored = WorkspaceStore(config: config, doc: restoredDoc)
        XCTAssertEqual(restored.chats.first?.displayTitle, "Release plan 📝")
        XCTAssertEqual(restoredDoc.pending.count, doc.pending.count)
        XCTAssertEqual(restoredDoc.pending.last?.ops.last?.set?["title"], .string("Release plan 📝"))
    }

    func testBlankUnchangedAndMissingTitlesDoNotQueueWrites() {
        let (model, doc) = workspace()
        let pending = doc.pending.count
        model.rename(chatId: "chat-a", title: " \n\t ")
        model.rename(chatId: "chat-a", title: " Original \n")
        model.rename(chatId: "missing", title: "Not a new session")
        XCTAssertEqual(model.chat(id: "chat-a")?.displayTitle, "Original")
        XCTAssertNil(model.chat(id: "missing"))
        XCTAssertEqual(doc.pending.count, pending)
    }

    func testDemoRenameOnlyChangesTheSelectedSession() {
        let first = Chat(id: "chat-a", deviceId: "host", title: "Original", archived: false, createdAt: 1)
        let second = Chat(id: "chat-b", deviceId: "host", title: "Other session", archived: false, createdAt: 2)
        let model = AppModel()
        model.demo = DemoDataset(devices: [], spaces: [], chats: [first, second], sessions: [:])
        model.rename(chatId: "chat-a", title: " Renamed ")
        XCTAssertEqual(model.chat(id: "chat-a")?.displayTitle, "Renamed")
        XCTAssertEqual(model.chat(id: "chat-b")?.displayTitle, "Other session")
        model.rename(chatId: "chat-a", title: " ")
        XCTAssertEqual(model.chat(id: "chat-a")?.displayTitle, "Renamed")
    }
}
