import XCTest
@testable import Harness

/// Four desktop features on the phone: Hide on the Archived shelf, the
/// No project filter, keep-awake and the attach sound.
@MainActor
final class DesktopParitySettingsTests: XCTestCase {
    private func chat(_ id: String, space: String? = nil, archived: Bool = false) -> Chat {
        Chat(id: id, deviceId: "studio", title: id, archived: archived, cwd: nil, branch: nil,
             checkoutId: nil, config: nil, lastMessagePreview: nil, lastMessageAt: nil,
             createdAt: 0, spaceId: space, lastSeenAt: nil)
    }

    private func names(_ chat: Chat) -> HomeFilter.Names { HomeFilter.Names(project: nil, device: "studio") }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.hiddenArchivedKey)
        UserDefaults.standard.removeObject(forKey: AttachSound.storageKey)
        super.tearDown()
    }

    // MARK: Hide

    func testHiddenArchivedSessionsLeaveTheShelfButSearchStillFindsThem() {
        let archived = [chat("upload-retry", archived: true), chat("theme-pass", archived: true)]
        let hidden: Set<String> = ["upload-retry"]
        XCTAssertEqual(HomeFilter.archivedShelf(archived, hidden: hidden, query: "", names: names).map(\.id),
                       ["theme-pass"])
        XCTAssertEqual(HomeFilter.archivedShelf(archived, hidden: hidden, query: "  ", names: names).map(\.id),
                       ["theme-pass"], "blank search is no search")
        XCTAssertEqual(HomeFilter.archivedShelf(archived, hidden: hidden, query: "upload", names: names).map(\.id),
                       ["upload-retry"])
    }

    func testHidingIsLocalAndUnarchivingBringsTheSessionBack() {
        UserDefaults.standard.removeObject(forKey: AppModel.hiddenArchivedKey)
        let model = AppModel()
        model.demo = DemoDataset(devices: [], spaces: [], chats: [chat("a", archived: true), chat("b", archived: true)],
                                 sessions: [:])
        model.hideArchived(chatId: "a")
        XCTAssertEqual(model.archivedMatches(in: nil, query: "").map(\.id), ["b"])
        XCTAssertTrue(model.chat(id: "a")?.archived == true, "hiding doesn't touch the session")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AppModel.hiddenArchivedKey), ["a"])
        model.unarchive(chatId: "a")
        XCTAssertFalse(model.hiddenArchivedIds.contains("a"))
        model.archive(chatId: "a")
        XCTAssertEqual(Set(model.archivedMatches(in: nil, query: "").map(\.id)), ["a", "b"],
                       "archived again later, it's back on the shelf")
    }

    // MARK: No project

    func testNoProjectKeepsOnlySessionsOutsideAnyProject() {
        let chats = [chat("loose"), chat("in-harness", space: "harness"), chat("also-loose")]
        XCTAssertEqual(HomeListControls.projectless(chats).map(\.id), ["loose", "also-loose"])
        XCTAssertEqual(HomeListControls.scopeTitle(projectName: nil, projectless: true), "No project")
        XCTAssertEqual(HomeListControls.scopeTitle(projectName: nil), "All projects")
        XCTAssertNotEqual(HomeListControls.projectlessFilter, "", "\"\" stays All")
    }

    func testTheArchivedShelfFollowsNoProject() {
        let model = AppModel()
        model.demo = DemoDataset(devices: [], spaces: [], chats: [
            chat("loose", archived: true), chat("in-harness", space: "harness", archived: true),
        ], sessions: [:])
        XCTAssertEqual(model.archivedMatches(in: HomeListControls.projectlessFilter, query: "").map(\.id), ["loose"])
        XCTAssertEqual(model.archivedMatches(in: "harness", query: "").map(\.id), ["in-harness"])
    }

    // MARK: Keep awake

    func testKeepAwakeReadsTheEnginesReply() throws {
        let reply = Data(#"{"enabled":true,"supported":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(KeepAwakeSetting.self, from: reply),
                       KeepAwakeSetting(enabled: true, supported: false))
    }

    func testDemoKeepAwakeRoundTrips() async throws {
        let model = AppModel()
        model.demo = DemoDataset(devices: [], spaces: [], chats: [], sessions: [:])
        let initial = try await model.keepAwake(deviceId: "mac")
        XCTAssertEqual(initial, KeepAwakeSetting(enabled: false, supported: true))
        let kept = try await model.setKeepAwake(deviceId: "mac", enabled: true)
        XCTAssertTrue(kept.enabled)
        let reread = try await model.keepAwake(deviceId: "mac")
        XCTAssertTrue(reread.enabled)
    }

    // MARK: Attach sound

    func testTheAttachSoundIsOffUntilSwitchedOnAndShips() {
        UserDefaults.standard.removeObject(forKey: AttachSound.storageKey)
        XCTAssertFalse(AttachSound.enabled, "off by default, like the desktop's")
        AttachSound.enabled = true
        XCTAssertTrue(AttachSound.enabled)
        XCTAssertNotNil(Bundle(for: AppModel.self).url(forResource: "attach", withExtension: "wav")
                        ?? Bundle.main.url(forResource: "attach", withExtension: "wav"))
    }
}
