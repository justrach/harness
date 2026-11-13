import XCTest
@testable import Harness

final class ComposerWorkspaceCommandTests: XCTestCase {
    func testChatCatalogIncludesEveryDesktopWorkspaceAction() {
        let rows = ComposerWorkspaceCommand.merging(providerCommands: [], inChat: true)
        XCTAssertEqual(rows.map(\.name), [
            "model", "new", "resume", "settings", "diff", "files", "terminal", "rename", "stop", "help",
        ])
        XCTAssertEqual(rows.compactMap(\.workspaceCommand), ComposerWorkspaceCommand.allCases)
        XCTAssertEqual(rows.count, 10)
    }

    func testDraftCatalogOmitsOnlyActionsWhichNeedAChat() {
        let rows = ComposerWorkspaceCommand.merging(providerCommands: [], inChat: false)
        XCTAssertEqual(rows.map(\.name), ["model", "new", "resume", "settings", "help"])
        XCTAssertEqual(Set(ComposerWorkspaceCommand.allCases.filter(\.needsChat)),
                       Set([.diff, .files, .terminal, .rename, .stop]))
    }

    func testProviderNamesAndMetadataSurviveRepeatedHarnessPrefixCollisions() throws {
        let providers = [
            ComposerCommand(name: "model", description: "Provider model", inputHint: "model name"),
            ComposerCommand(name: "help", description: "Provider help"),
            ComposerCommand(name: "harness:model", description: "Provider prefixed model"),
        ]
        let rows = ComposerWorkspaceCommand.merging(providerCommands: providers, inChat: true)
        XCTAssertEqual(Array(rows.prefix(providers.count)), providers)
        XCTAssertTrue(rows.prefix(providers.count).allSatisfy { $0.workspaceCommand == nil })
        XCTAssertEqual(rows.count, providers.count + 10)
        XCTAssertEqual(Set(rows.map(\.name)).count, rows.count)
        let model = try XCTUnwrap(rows.first { $0.workspaceCommand == .model })
        XCTAssertEqual(model.name, "harness:harness:model")
        let help = try XCTUnwrap(rows.first { $0.workspaceCommand == .help })
        XCTAssertEqual(help.name, "harness:help")
    }

    func testMergeIsIdempotentAndRegatesWorkspaceRows() {
        let provider = ComposerCommand(name: "stop", description: "Provider stop remains available in drafts")
        let chatRows = ComposerWorkspaceCommand.merging(providerCommands: [provider], inChat: true)
        XCTAssertEqual(ComposerWorkspaceCommand.merging(providerCommands: chatRows, inChat: true), chatRows)
        let draftRows = ComposerWorkspaceCommand.merging(providerCommands: chatRows, inChat: false)
        XCTAssertEqual(draftRows.first, provider)
        XCTAssertEqual(draftRows.count, 6)
        XCTAssertFalse(draftRows.compactMap(\.workspaceCommand).contains(.stop))
    }

    func testDesktopOnlyActionsAreExactlyTheUnsupportedTriad() {
        let desktopOnly = ComposerWorkspaceCommand.allCases.filter(\.isDesktopOnly)
        XCTAssertEqual(desktopOnly, [.diff, .files, .terminal])
        for action in desktopOnly {
            XCTAssertTrue(action.description.contains("desktop only"), action.rawValue)
        }
        for action in ComposerWorkspaceCommand.allCases where !action.isDesktopOnly {
            XCTAssertFalse(action.description.contains("desktop only"), action.rawValue)
        }
    }

    func testDecodedProviderCommandsNeverAcquireWorkspaceAuthority() throws {
        // Even a provider's extra field must not turn its row into a native
        // action. Only the local merge is allowed to assign this metadata.
        for action in ComposerWorkspaceCommand.allCases {
            let json = """
            {"name":"\(action.rawValue)","description":"Provider command","workspaceCommand":"\(action.rawValue)"}
            """
            let decoded = try JSONDecoder().decode(ComposerCommand.self, from: Data(json.utf8))
            XCTAssertNil(decoded.workspaceCommand, action.rawValue)
            let rows = ComposerWorkspaceCommand.merging(providerCommands: [decoded], inChat: true)
            XCTAssertEqual(rows.first, decoded)
            XCTAssertNil(rows.first?.workspaceCommand)
            XCTAssertEqual(rows.first { $0.workspaceCommand == action }?.name, "harness:\(action.rawValue)")
        }
    }
}
