package harness.codegraff.android.model

/**
 * Chat mode: a plain conversation instead of a coding session. No project, graff on the hosted
 * gateway's auto tiers only, offered as Auto (low), Auto (high) and Auto (smart).
 * Mirrors crates/ui/src/chat_mode.rs and ChatMode.swift; apps/parity/vectors/chat-mode.json pins both phones.
 */
object ChatMode {
    /** Chat mode always runs on graff, which reaches the hosted gateway. */
    const val HARNESS = "graff"

    /** Under Auto (smart) in the model picker: it's billed at API rates. */
    const val SMART_COST_NOTE = "May incur API costs."

    /** [SMART_COST_NOTE] above the composer, away from the model chip, so it names the tier. */
    const val SMART_FOOTER_NOTE = "Auto (smart) may incur API costs."

    /** Why a chat can't start: the device's graff lists none of the tiers (an older gateway, signed out, offline). */
    const val UNAVAILABLE_NOTE = "Chat needs the hosted Auto models, which aren't available right now."

    data class Tier(val id: String, val fallbackId: String?, val label: String, val note: String?, val footerNote: String?)

    val tiers = listOf(
        Tier("codegraff/auto-low", "codegraff/auto-medium", "Auto (low)", null, null),
        Tier("codegraff/auto-high", null, "Auto (high)", null, null),
        Tier("codegraff/auto-smart", null, "Auto (smart)", SMART_COST_NOTE, SMART_FOOTER_NOTE),
    )

    enum class Availability { Pending, Available, Unavailable }

    /** The chat-mode models graff's catalog lists, in tier order, under the tier names. A tier it doesn't list is left out. */
    fun models(catalog: List<ModelInfo>): List<ModelInfo> = tiers.mapNotNull { tier ->
        val row = catalog.firstOrNull { it.id == tier.id }
            ?: tier.fallbackId?.let { id -> catalog.firstOrNull { it.id == id } }
            ?: return@mapNotNull null
        ModelInfo(row.id, tier.label, tier.note, emptyList())
    }

    /**
     * Whether a chat can run on this device: a tier is listed, or a successful reply (graff's catalog, or the agent
     * list without graff) proved none is. Until then it's pending.
     */
    fun availability(catalog: DeviceCatalog<ModelInfo>, harnesses: DeviceCatalog<HarnessInfo> = DeviceCatalog()): Availability = when {
        models(catalog.items).isNotEmpty() -> Availability.Available
        harnesses.isLive && harnesses.items.none { it.id == HARNESS } -> Availability.Unavailable
        catalog.isLive -> Availability.Unavailable
        else -> Availability.Pending
    }

    /** A new chat's model: its own last pick if still listed, else the first tier. Nothing to send on while none is listed. */
    fun selection(chatModelId: String?, catalog: DeviceCatalog<ModelInfo>, harnesses: DeviceCatalog<HarnessInfo> = DeviceCatalog()): ModelSelection {
        val offered = models(catalog.items)
        val picked = offered.firstOrNull { it.id == chatModelId } ?: offered.firstOrNull() ?: ModelInfo("", "Select model", null, emptyList())
        return ModelSelection(picked, null, availability(catalog, harnesses) == Availability.Unavailable)
    }

    /** The line above the composer while [modelId] is selected (the API-cost note for Auto (smart)). */
    fun note(modelId: String?): String? =
        modelId?.let { id -> tiers.firstOrNull { it.id == id || it.fallbackId == id }?.footerNote }
}
