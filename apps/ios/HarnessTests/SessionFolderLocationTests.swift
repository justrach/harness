import XCTest
@testable import Harness

final class SessionFolderLocationTests: XCTestCase {
    func testAbbreviatesMacLinuxAndWindowsHomeDirectories() {
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/Users/dev"), "~")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/Users/dev/"), "~")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/Users/dev/harness"), "~/harness")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/Users/dev/harness/apps/ios/"), "~/harness/apps/ios")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/Users/dev/.harness/worktrees/harness-veil-fade"),
                       "~/.harness/worktrees/harness-veil-fade")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/home/dev/edge"), "~/edge")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("C:\\Users\\dev\\repos\\harness"), "~/repos/harness")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("~"), "~")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("~/"), "~")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("~/scratch/"), "~/scratch")
    }

    func testPreservesNonHomePathsAndRejectsBlankInput() {
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/srv/deploys/edge/"), "/srv/deploys/edge")
        XCTAssertEqual(SessionFolderLocation.abbreviatePath("/"), "/")
        XCTAssertNil(SessionFolderLocation.abbreviatePath(nil))
        XCTAssertNil(SessionFolderLocation.abbreviatePath("   "))
    }

    func testProjectSessionPrefersWorkingFolderOverProjectRoot() {
        let root = SessionFolderLocation.resolve(
            cwd: "/Users/dev/harness",
            spaceId: "space-harness",
            spacePath: "/Users/dev/harness",
            spaceName: "harness",
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(root, .init(label: "~/harness", device: "MacBook Pro", spaceId: "space-harness"))
        XCTAssertEqual(root.plainText, "~/harness @ MacBook Pro")

        let worktree = SessionFolderLocation.resolve(
            cwd: "/Users/dev/.harness/worktrees/harness-veil-fade",
            spaceId: "space-harness",
            spacePath: "/Users/dev/harness",
            spaceName: "harness",
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(worktree.plainText, "~/.harness/worktrees/harness-veil-fade @ MacBook Pro")
        XCTAssertEqual(worktree.spaceId, "space-harness")
    }

    func testProjectSessionFallsBackToSpacePathThenName() {
        let fromSpacePath = SessionFolderLocation.resolve(
            cwd: nil,
            spaceId: "space-harness",
            spacePath: "/Users/dev/harness",
            spaceName: "harness",
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(fromSpacePath.plainText, "~/harness @ MacBook Pro")

        let fromSpaceName = SessionFolderLocation.resolve(
            cwd: nil,
            spaceId: "space-harness",
            spacePath: nil,
            spaceName: "harness",
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(fromSpaceName.plainText, "harness @ MacBook Pro")
    }

    func testProjectlessAndPlainChatModes() {
        let homeFolder = SessionFolderLocation.resolve(
            cwd: "~",
            spaceId: nil,
            spacePath: nil,
            spaceName: nil,
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(homeFolder, .init(label: "~", device: "MacBook Pro", spaceId: nil))
        XCTAssertEqual(homeFolder.plainText, "~ @ MacBook Pro")

        let customFolder = SessionFolderLocation.resolve(
            cwd: "/Users/dev/Downloads/repro",
            spaceId: nil,
            spacePath: nil,
            spaceName: nil,
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(customFolder.plainText, "~/Downloads/repro @ MacBook Pro")

        let unknownFolder = SessionFolderLocation.resolve(
            cwd: nil,
            spaceId: nil,
            spacePath: nil,
            spaceName: nil,
            isChatMode: false,
            device: "MacBook Pro"
        )
        XCTAssertEqual(unknownFolder.plainText, "No project @ MacBook Pro")

        let chatMode = SessionFolderLocation.resolve(
            cwd: "~",
            spaceId: nil,
            spacePath: nil,
            spaceName: nil,
            isChatMode: true,
            device: "MacBook Pro"
        )
        XCTAssertEqual(chatMode.plainText, "Chat @ MacBook Pro")
    }
}
