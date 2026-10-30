// Chat mode: a plain conversation instead of a coding session. No project,
// graff on the hosted gateway's auto tiers only, offered as Auto (low),
// Auto (high) and Auto (smart). Mirrors crates/ui/src/chat_mode.rs;
// apps/parity/vectors/chat-mode.json pins it with the Android port.

import Foundation

enum ChatMode {
    /// Chat mode always runs on graff, which reaches the hosted gateway.
    static let harness = "graff"

    /// Under Auto (smart) in the model picker: it's billed at API rates.
    static let smartCostNote = "May incur API costs."

    /// `smartCostNote` above the composer, away from the model chip, so it
    /// names the tier.
    static let smartFooterNote = "Auto (smart) may incur API costs."

    /// Why a chat can't start: the device's graff lists none of the tiers
    /// (an older gateway, signed out, offline).
    static let unavailableNote = "Chat needs the hosted Auto models, which aren't available right now."

    struct Tier: Equatable {
        /// The id graff lists (`<provider>/<model>`).
        let id: String
        /// Older gateways list the same tier under this id.
        let fallbackId: String?
        let label: String
        /// Under the row in the model picker.
        let note: String?
        /// Above the composer while the tier is selected.
        let footerNote: String?
    }

    static let tiers: [Tier] = [
        Tier(id: "codegraff/auto-low", fallbackId: "codegraff/auto-medium", label: "Auto (low)",
             note: nil, footerNote: nil),
        Tier(id: "codegraff/auto-high", fallbackId: nil, label: "Auto (high)",
             note: nil, footerNote: nil),
        Tier(id: "codegraff/auto-smart", fallbackId: nil, label: "Auto (smart)",
             note: smartCostNote, footerNote: smartFooterNote),
    ]

    enum Availability: String {
        case pending, available, unavailable
    }

    /// The chat-mode models graff's catalog lists, in tier order, under the
    /// tier names. A tier it doesn't list is left out.
    static func models(from catalog: [ModelInfo]) -> [ModelInfo] {
        tiers.compactMap { tier in
            guard let row = catalog.first(where: { $0.id == tier.id })
                ?? tier.fallbackId.flatMap({ id in catalog.first(where: { $0.id == id }) }) else { return nil }
            return ModelInfo(id: row.id, label: tier.label, description: tier.note,
                             reasoningLevels: [], options: [])
        }
    }

    /// Whether a chat can run on this device: a tier is listed, or a
    /// successful reply (`liveModels`, graff's catalog, or `liveHarnesses`
    /// without graff) proved none is. Until then it's pending.
    static func availability(catalog: [ModelInfo], liveHarnesses: [HarnessInfo]?,
                             liveModels: [ModelInfo]?) -> Availability {
        if !models(from: catalog).isEmpty { return .available }
        if let liveHarnesses, !liveHarnesses.contains(where: { $0.id == harness }) { return .unavailable }
        if liveModels != nil { return .unavailable }
        return .pending
    }

    /// A new chat's model: its own last pick if still listed, else the first
    /// tier. Nothing to send on while none is listed.
    static func selectedModel(storedId: String, catalog: [ModelInfo], loading: Bool) -> ModelInfo {
        let offered = models(from: catalog)
        return offered.first { $0.id == storedId }
            ?? offered.first
            ?? ModelInfo(id: "", label: loading ? "Loading models…" : "Select model",
                         description: nil, reasoningLevels: [])
    }

    /// The line above the composer while `modelId` is selected (the API-cost
    /// note for Auto (smart)).
    static func note(for modelId: String?) -> String? {
        guard let modelId else { return nil }
        return tiers.first { $0.id == modelId || $0.fallbackId == modelId }?.footerNote
    }
}
