import XCTest
@testable import Harness

@MainActor
final class ChildSessionVisibilityTests: XCTestCase {
    private var config: AppConfig {
        AppConfig(edgeURL: URL(string: "http://localhost:1")!, mode: .dev,
                  userId: "child-visibility-tests", orgId: "tests", deviceId: "phone",
                  deviceName: "Test phone", devBearer: "child-visibility-tests@tests")
    }

    private func fixture() -> RegistryDoc {
        let doc = RegistryDoc(deviceId: "phone")
        doc.write(kind: "spaces", id: "project", op: .upsert, set: [
            "deviceId": .string("host"), "path": .string("/synthetic/project"),
        ])
        func chat(_ id: String, parent: String? = nil, archived: Bool = false,
                  project: Bool = true) {
            var fields: [String: JSONValue] = [
                "deviceId": .string("host"), "title": .string(id),
                "archived": .bool(archived), "lastMessageAt": .int(100),
                "roomGen": .int(2),
            ]
            if project { fields["spaceId"] = .string("project") }
            if let parent { fields["parentChatId"] = .string(parent) }
            doc.write(kind: "chats", id: id, op: .upsert, set: fields)
        }
        chat("parent")
        chat("child", parent: "parent")
        chat("nested", parent: "child")
        chat("orphan", parent: "missing", project: false)
        chat("archived-parent", archived: true)
        chat("archived-child", parent: "parent", archived: true)
        chat("legacy", project: false)
        doc.initializeSidebarPins()
        _ = doc.changeSidebarPin(id: "child", pinned: true)
        return doc
    }

    func testChildRowsStaySyncedButNeverBecomeSessionListEntries() throws {
        let doc = fixture()
        // Exercise disk hydration too: hiding a child must not delete it or
        // rewrite the shared registry merely to tidy this phone's lists.
        let restored = try RegistryDoc.from(data: doc.toData(), deviceId: "phone")
        let store = WorkspaceStore(config: config, doc: restored)
        XCTAssertEqual(store.chats.count, 7)
        XCTAssertEqual(Set(store.overviewChats.map(\.id)), ["parent", "legacy"])
        XCTAssertEqual(store.chats(in: "project").map(\.id), ["parent"])
        XCTAssertEqual(store.archivedChats().map(\.id), ["archived-parent"])
        XCTAssertEqual(store.archivedChats(in: "project").map(\.id), ["archived-parent"])
        XCTAssertNotNil(restored.overlayRow(kind: "chats", id: "child"))
        XCTAssertEqual(restored.pending.count, doc.pending.count)
    }

    func testChildChatsCannotBeOpenedOrPagedToFromTheAppModel() {
        let model = AppModel()
        model.workspace = WorkspaceStore(config: config, doc: fixture())
        XCTAssertNil(model.chat(id: "child"))
        XCTAssertNotNil(model.chat(id: "parent"))
        XCTAssertEqual(Set(JuggledSessions(model: model).chats.map(\.id)), ["parent", "legacy"])
        XCTAssertEqual(Set(SessionPaging.entries(model: model, including: "child").map(\.id)),
                       ["parent", "legacy"])
        model.openDeepLink(URL(string: "harness://chat/child")!)
        XCTAssertNil(model.launchRoute)
        model.openDeepLink(URL(string: "harness://chat/parent")!)
        XCTAssertEqual(model.launchRoute, .chat("parent"))
    }

    func testDemoAndLiveListsUseTheSameChildVisibilityRule() {
        let model = AppModel()
        let store = WorkspaceStore(config: config, doc: fixture())
        model.demo = DemoDataset(devices: [], spaces: store.spaces, chats: store.chats, sessions: [:])
        model.demoPinnedSessionIds = ["child"]
        XCTAssertEqual(Set(model.overviewChats.map(\.id)), ["parent", "legacy"])
        XCTAssertEqual(model.chats(in: "project").map(\.id), ["parent"])
        XCTAssertEqual(model.archivedChats().map(\.id), ["archived-parent"])
        XCTAssertNil(model.chat(id: "child"))
    }

    func testIncomingParentLinkImmediatelyRemovesAnExistingThreadFromLists() {
        let store = WorkspaceStore(config: config)
        func row(_ parent: JSONValue) -> RegistryRow {
            RegistryRow(kind: "chats", id: "worker", seq: 1, deleted: false, delHlc: nil,
                        fields: ["deviceId": .string("host"), "parentChatId": parent], clocks: [:])
        }
        store.handle(.state(seq: 1, full: true, gcFloor: 0, rows: [row(.null)], presence: [:]))
        XCTAssertEqual(store.overviewChats.map(\.id), ["worker"])
        store.handle(.state(seq: 2, full: false, gcFloor: 0,
                            rows: [row(.string("parent"))], presence: [:]))
        XCTAssertTrue(store.overviewChats.isEmpty)
        XCTAssertEqual(store.chats.map(\.id), ["worker"])
    }
}
