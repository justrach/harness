import XCTest
@testable import Harness

/// Chat mode offers graff's three auto tiers only, under their picker names,
/// notes the API costs of Auto (smart), and says so plainly when the device
/// lists none of them. Mirrors crates/ui/src/chat_mode.rs.
final class ChatModeTests: XCTestCase {
    private func model(_ id: String, _ label: String) -> ModelInfo {
        ModelInfo(id: id, label: label, description: nil, reasoningLevels: ["low", "high"])
    }

    func testOnlyTheAutoTiersAreOfferedInOrderUnderTheirNames() {
        let catalog = [
            model("codegraff/auto-smart", "auto-smart"),
            model("codegraff/claude-opus-5-5", "Claude Opus 5.5"),
            model("codegraff/auto-high", "Auto (high)"),
            model("chatgpt-new/gpt-6.1-sol", "GPT-6.1 Sol"),
            model("codegraff/auto-low", "Auto (low)"),
        ]
        let offered = ChatMode.models(from: catalog)
        XCTAssertEqual(offered.map(\.id), ["codegraff/auto-low", "codegraff/auto-high", "codegraff/auto-smart"])
        XCTAssertEqual(offered.map(\.label), ["Auto (low)", "Auto (high)", "Auto (smart)"])
        XCTAssertEqual(offered[2].description, "May incur API costs.")
        XCTAssertTrue(offered.allSatisfy { $0.reasoningLevels.isEmpty }, "the tier picks its own thinking")
    }

    func testAnOlderGatewayOffersAutoMediumAsAutoLow() {
        let offered = ChatMode.models(from: [model("codegraff/auto-medium", "Auto (medium)"),
                                             model("codegraff/auto-high", "Auto (high)")])
        XCTAssertEqual(offered.map(\.id), ["codegraff/auto-medium", "codegraff/auto-high"])
        XCTAssertEqual(offered.first?.label, "Auto (low)")
    }

    func testNoTierIsInventedBeforeOrWithoutTheCatalog() {
        XCTAssertTrue(ChatMode.models(from: []).isEmpty)
        let pending = ChatMode.selectedModel(storedId: "", catalog: [], loading: true)
        XCTAssertEqual(pending.id, "", "nothing to send on until a tier is listed")
        XCTAssertEqual(pending.label, "Loading models…")
        XCTAssertEqual(ChatMode.selectedModel(storedId: "", catalog: [], loading: false).label, "Select model")
    }

    func testAvailabilityWaitsForAReplyThenSaysWhy() {
        let tiers = [model("codegraff/auto-low", "Auto (low)")]
        let other = [model("codegraff/claude-opus-5-5", "Claude Opus 5.5")]
        let graff = [HarnessInfo(id: "graff", label: "Graff")]
        XCTAssertEqual(ChatMode.availability(catalog: [], liveHarnesses: nil, liveModels: nil), .pending)
        XCTAssertEqual(ChatMode.availability(catalog: tiers, liveHarnesses: nil, liveModels: nil), .available,
                       "cached tiers are enough")
        XCTAssertEqual(ChatMode.availability(catalog: other, liveHarnesses: graff, liveModels: other), .unavailable)
        XCTAssertEqual(ChatMode.availability(catalog: [], liveHarnesses: [HarnessInfo(id: "codex", label: "Codex")],
                                             liveModels: nil), .unavailable, "graff isn't on the device")
        XCTAssertEqual(ChatMode.unavailableNote,
                       "Chat needs the hosted Auto models, which aren't available right now.")
    }

    func testTheCostNoteBelongsToAutoSmartOnly() {
        XCTAssertEqual(ChatMode.note(for: "codegraff/auto-smart"), "Auto (smart) may incur API costs.")
        XCTAssertNil(ChatMode.note(for: "codegraff/auto-high"))
        XCTAssertNil(ChatMode.note(for: "codegraff/auto-medium"))
        XCTAssertNil(ChatMode.note(for: nil))
    }

    func testAChatConfigRoundTripsItsMode() throws {
        let chat = ChatConfig(harness: "graff", model: "codegraff/auto-low", reasoning: nil,
                              sandbox: "workspace-write", chatMode: true)
        let data = try JSONEncoder().encode(chat)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"chatMode\":true"))
        XCTAssertTrue(try JSONDecoder().decode(ChatConfig.self, from: data).isChatMode)

        let code = ChatConfig(harness: "codex", model: "gpt-6-sol", reasoning: nil, sandbox: "workspace-write")
        let codeData = try JSONEncoder().encode(code)
        XCTAssertFalse(String(decoding: codeData, as: UTF8.self).contains("chatMode"), "omitted on coding sessions")
        XCTAssertFalse(try JSONDecoder().decode(ChatConfig.self, from: codeData).isChatMode)
    }
}
