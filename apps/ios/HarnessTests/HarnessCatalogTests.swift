import XCTest
@testable import Harness

final class HarnessCatalogTests: XCTestCase {
    func testCodexFallbackStartsWithAstraAndExposesItsTraits() {
        let models = HarnessCatalog.models(for: "codex")
        let astra = models.first

        XCTAssertEqual(astra?.id, "gpt-6-astra")
        XCTAssertEqual(astra?.label, "GPT-6-Astra")
        XCTAssertEqual(astra?.reasoningLevels,
                       ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(astra?.options.first?.id, "serviceTier")
        XCTAssertEqual(astra?.options.first?.choices.map(\.id), ["default", "fast"])
    }

    func testDefaultReasoningMatchesDesktopPreference() {
        let astra = HarnessCatalog.defaultModel(for: "codex")
        XCTAssertEqual(HarnessCatalog.defaultReasoning(for: astra), "high")

        let short = ModelInfo(id: "short", label: "Short", description: nil,
                              reasoningLevels: ["low", "medium"])
        XCTAssertEqual(HarnessCatalog.defaultReasoning(for: short), "medium")
    }

    func testChoiceFallsBackToAdvertisedDefault() {
        let option = HarnessCatalog.defaultModel(for: "codex").options[0]
        XCTAssertEqual(HarnessCatalog.selectedChoice(for: option, selectedId: "fast").label, "Fast")
        XCTAssertEqual(HarnessCatalog.selectedChoice(for: option, selectedId: "stale").id, "default")
    }

    func testNormalizeDropsDefaultWhenRealRowsExistButKeepsItAlone() {
        let defaultRow = ModelInfo(id: "default", label: "Default", description: nil, reasoningLevels: [])
        let realRow = ModelInfo(id: "titan", label: "Titan", description: nil, reasoningLevels: [])

        XCTAssertEqual(HarnessCatalog.normalize(harness: "other", models: [defaultRow, realRow]).map(\.id),
                       ["titan"])
        XCTAssertEqual(HarnessCatalog.normalize(harness: "other", models: [defaultRow]).map(\.id),
                       ["default"])
    }

    func testNormalizeFoldsOrphanLongContextVariant() {
        let row = ModelInfo(id: "titan[1m]", label: "Titan (1M context)",
                            description: "A model", reasoningLevels: ["high"])
        let normalized = HarnessCatalog.normalize(harness: "other", models: [row])

        XCTAssertEqual(normalized.first?.id, "titan")
        XCTAssertEqual(normalized.first?.label, "Titan")
        XCTAssertEqual(normalized.first?.options.first?.id, "contextWindow")
        XCTAssertEqual(normalized.first?.options.first?.defaultChoice, "1m")
    }

    func testNormalizeDropsLongContextVariantWhenBaseIsListed() {
        let base = ModelInfo(id: "claude-opus-5", label: "Opus", description: nil, reasoningLevels: [])
        let variant = ModelInfo(id: "claude-opus-5[1m]", label: "Opus (1M context)",
                                description: nil, reasoningLevels: [])

        XCTAssertEqual(HarnessCatalog.normalize(harness: "claude-code", models: [base, variant]).map(\.id),
                       ["claude-opus-5"])
    }

    func testNormalizeUsesCuratedAliasLabel() {
        let row = ModelInfo(id: "opus", label: "Opus", description: nil, reasoningLevels: [])
        XCTAssertEqual(HarnessCatalog.normalize(harness: "claude-code", models: [row]).first?.label,
                       "Opus 5")
    }

    func testResolvePreservesUnknownConfiguredModel() {
        let catalog = HarnessCatalog.models(for: "claude-code")
        XCTAssertEqual(HarnessCatalog.resolve(modelId: "claude-opus-5[1m]", in: catalog,
                                              harness: "claude-code").id, "claude-opus-5[1m]")
        let unknown = HarnessCatalog.resolve(modelId: "foo-9", in: catalog, harness: "claude-code")
        XCTAssertEqual(unknown.id, "foo-9")
        XCTAssertEqual(unknown.label, "foo-9")
    }

    func testLongContextAliasesKeepWireIdentityAndWindowAcrossHydration() {
        let catalog = HarnessCatalog.models(for: "claude-code")
        for saved in ["claude-opus-5[1m]", "claude-opus-5-1m"] {
            let pending = HarnessCatalog.resolve(modelId: saved, in: [], harness: "claude-code")
            let loaded = HarnessCatalog.resolve(modelId: saved, in: catalog, harness: "claude-code")
            XCTAssertEqual(pending.id, saved)
            XCTAssertEqual(loaded.id, pending.id)
            let option = loaded.options.first { $0.id == "contextWindow" }
            XCTAssertEqual(option?.defaultChoice, "1m")
            XCTAssertEqual(option.flatMap { $0.choices.first { $0.id == "1m" } }?.label, "1M")
            XCTAssertEqual(HarnessCatalog.resolveExisting(modelId: saved, in: catalog)?.id, "claude-opus-5")
        }
    }

    func testUnknownHarnessDoesNotInheritClaudeModelsOrOptions() {
        XCTAssertTrue(HarnessCatalog.models(for: "dynamic-agent").isEmpty)
        let fallback = HarnessCatalog.defaultModel(for: "dynamic-agent")
        XCTAssertEqual(fallback.label, "Default model")
        XCTAssertTrue(fallback.options.isEmpty)
        XCTAssertTrue(fallback.reasoningLevels.isEmpty)
    }

    func testSavedSelectionSurvivesMissingAndHydratedCatalogs() {
        let savedId = "saved-live-only"
        let pending = HarnessCatalog.resolve(modelId: savedId, in: [], harness: "dynamic-agent")
        XCTAssertEqual(pending.id, savedId)
        XCTAssertEqual(pending.label, savedId)
        XCTAssertTrue(pending.options.isEmpty)
        let live = ModelInfo(id: savedId, label: "Saved live model", description: nil,
                             reasoningLevels: ["high"])
        let hydrated = HarnessCatalog.resolve(modelId: savedId, in: [live], harness: "dynamic-agent")
        XCTAssertEqual(hydrated.id, pending.id)
        XCTAssertEqual(hydrated, live)
    }

    func testUnavailableSelectionRequiresLiveEvidence() {
        let harness = "dynamic-agent"
        let saved = "saved-live-only"
        XCTAssertFalse(HarnessCatalog.selectionUnavailable(harness: harness, modelId: saved,
            liveHarnesses: nil, liveModels: nil), "offline/unverified selections remain queueable")
        XCTAssertTrue(HarnessCatalog.selectionUnavailable(harness: harness, modelId: saved,
            liveHarnesses: [], liveModels: nil), "a live empty agent list is authoritative")
        XCTAssertTrue(HarnessCatalog.selectionUnavailable(harness: harness, modelId: saved,
            liveHarnesses: [HarnessInfo(id: harness, label: "Agent")], liveModels: []))
        let model = ModelInfo(id: saved, label: "Saved", description: nil, reasoningLevels: [])
        XCTAssertFalse(HarnessCatalog.selectionUnavailable(harness: harness, modelId: saved,
            liveHarnesses: [HarnessInfo(id: harness, label: "Agent")], liveModels: [model]))
    }

    func testClaudeCatalogStartsWithFable51AndContextWindow() {
        let first = HarnessCatalog.models(for: "claude-code").first
        XCTAssertEqual(first?.id, "claude-fable-5-1")
        XCTAssertEqual(first?.options.first?.id, "contextWindow")
    }

    func testOrderedModelsPlacesSubscriptionsBeforeNonSubscriptions() {
        let sample = [
            ModelInfo(id: "codegraff/kimi-k3", label: "kimi-k3", description: nil,
                      reasoningLevels: [], billing: "credits"),
            ModelInfo(id: "kimi/kimi-for-coding", label: "kimi-for-coding", description: nil,
                      reasoningLevels: [], billing: "plan"),
            ModelInfo(id: "kimi/k3.1-pro", label: "k3.1-pro", description: nil,
                      reasoningLevels: [], billing: "plan"),
        ]
        XCTAssertEqual(HarnessCatalog.orderedModels(sample).map(\.id), [
            "kimi/kimi-for-coding",
            "kimi/k3.1-pro",
            "codegraff/kimi-k3",
        ])
        XCTAssertEqual(HarnessCatalog.orderedModels(sample, query: "kimi").map(\.id), [
            "kimi/kimi-for-coding",
            "kimi/k3.1-pro",
            "codegraff/kimi-k3",
        ])
    }
}
