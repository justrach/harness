import XCTest
@testable import Harness

@MainActor
final class DraftStoreTests: XCTestCase {
    private let key = DraftStore.chatKey("draft-store-test")

    override func setUp() {
        DraftStore.persistsToDisk = true
        DraftStore.wipeAll()
    }

    override func tearDown() {
        DraftStore.wipeAll()
        DraftStore.persistsToDisk = true
    }

    func testADraftComesBackForTheSameChatOnly() {
        DraftStore.save("half a thought", for: key)
        XCTAssertEqual(DraftStore.load(key), "half a thought")
        XCTAssertEqual(DraftStore.load(DraftStore.chatKey("another-chat")), "")
    }

    func testSendingClearsTheDraft() {
        DraftStore.save("about to send", for: key)
        DraftStore.save("", for: key)
        XCTAssertEqual(DraftStore.load(key), "")
    }

    func testWhitespaceIsNotADraft() {
        DraftStore.save("kept", for: key)
        DraftStore.save("  \n ", for: key)
        XCTAssertEqual(DraftStore.load(key), "")
    }

    func testTrailingSpacesInARealDraftSurvive() {
        DraftStore.save("typing a sentence ", for: key)
        XCTAssertEqual(DraftStore.load(key), "typing a sentence ")
    }

    func testDraftsReachDiskAndAreReadBackWithoutTheInMemoryCopy() {
        DraftStore.save("still here after a relaunch", for: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "draft." + key), "still here after a relaunch")
    }

    func testDemoModeNeverWritesADraftToDisk() {
        DraftStore.persistsToDisk = false
        DraftStore.save("demo text", for: key)
        XCTAssertEqual(DraftStore.load(key), "demo text", "still remembered while navigating")
        XCTAssertNil(UserDefaults.standard.string(forKey: "draft." + key))
    }

    func testSigningOutWipesEveryDraft() {
        DraftStore.save("one", for: key)
        DraftStore.save("two", for: DraftStore.newSessionKey(.project(spaceId: "space-1")))
        DraftStore.wipeAll()
        XCTAssertEqual(DraftStore.load(key), "")
        XCTAssertEqual(DraftStore.load(DraftStore.newSessionKey(.project(spaceId: "space-1"))), "")
        XCTAssertNil(UserDefaults.standard.string(forKey: "draft." + key))
    }

    func testNewSessionDraftsAreKeptPerDestination() {
        let project = DraftStore.newSessionKey(.project(spaceId: "s1"))
        let host = DraftStore.newSessionKey(.projectless(deviceId: "s1"))
        XCTAssertNotEqual(project, host)
        DraftStore.save("for the project", for: project)
        XCTAssertEqual(DraftStore.load(host), "")
    }
}
