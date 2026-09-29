package harness.codegraff.android.model

// Harness and model catalogs: ports of crates/harness's curated static catalogs
// (HarnessCatalog.swift). The desktop discovers at runtime; the phone mirrors its run
// device's live catalog and falls back to these. Defaults mirror pickers.rs: the first
// catalog row, reasoning high where the ladder has it, else medium/first.

data class HarnessInfo(val id: String, val label: String)

data class ModelOptionChoiceInfo(val id: String, val label: String)

data class ModelOptionInfo(
    val id: String,
    val label: String,
    val choices: List<ModelOptionChoiceInfo>,
    val defaultChoice: String,
)

data class ModelInfo(
    val id: String,
    val label: String,
    val description: String?,
    /** Unified reasoning ladder, lowercase wire values. Empty means no efforts. */
    val reasoningLevels: List<String>,
    /** Harness-specific traits such as Codex Standard/Fast. */
    val options: List<ModelOptionInfo> = emptyList(),
)

object HarnessCatalog {
    /** Static fallback: the engine's `default_enabled()` pair. The ACP agents appear only through a device's live catalog. */
    val harnesses = listOf(HarnessInfo("claude-code", "Claude Code"), HarnessInfo("codex", "Codex"))

    /** Display names for every harness id the fleet can produce. */
    private val knownLabels = mapOf(
        "claude-code" to "Claude Code", "codex" to "Codex", "devin" to "Devin", "grok" to "Grok",
        "hermes" to "Hermes", "pi" to "Pi", "cursor" to "Cursor", "opencode" to "OpenCode",
        "antigravity" to "Antigravity", "exo" to "Exo", "mock" to "Mock",
    )

    fun label(harness: String): String = knownLabels[harness] ?: harness

    private val fullLadder = listOf("low", "medium", "high", "xhigh", "max", "ultracode", "ultrathink")
    private val claudeXhighLadder = listOf("low", "medium", "high", "xhigh", "max", "ultrathink")
    private val codexUltraLadder = listOf("low", "medium", "high", "xhigh", "max", "ultra")
    private val codexMaxLadder = listOf("low", "medium", "high", "xhigh", "max")
    private val codexXhighLadder = listOf("low", "medium", "high", "xhigh")

    private val codexServiceTier = listOf(
        ModelOptionInfo(
            "serviceTier", "Service Tier",
            listOf(ModelOptionChoiceInfo("default", "Standard"), ModelOptionChoiceInfo("fast", "Fast")),
            "default",
        ),
    )

    private val claudeContextWindow = ModelOptionInfo(
        "contextWindow", "Context Window",
        listOf(ModelOptionChoiceInfo("200k", "200K"), ModelOptionChoiceInfo("1m", "1M")),
        "200k",
    )

    private fun toggle(id: String, label: String) = ModelOptionInfo(
        id, label, listOf(ModelOptionChoiceInfo("off", "Off"), ModelOptionChoiceInfo("on", "On")), "off",
    )

    fun models(harness: String): List<ModelInfo> = when (harness) {
        "grok" -> listOf(
            ModelInfo("grok-4.5", "Grok 4.5", "xAI's coding model — 500k context", listOf("low", "medium", "high")),
        )
        "devin" -> listOf(
            ModelInfo("swe-1-7-medium", "SWE-1.7 Medium", "Devin's default coding model", emptyList()),
            ModelInfo("claude-fable-5-1-high", "Claude Fable 5.1 High", "Anthropic's frontier model through Devin", emptyList()),
            ModelInfo("adaptive", "Adaptive", "Devin picks the model per request", emptyList()),
        )
        "hermes" -> listOf(
            ModelInfo("hermes-4-405b", "Hermes 4 405B", "Nous Research's hybrid-reasoning flagship", emptyList()),
            ModelInfo("hermes-4-70b", "Hermes 4 70B", "Faster Hermes 4 — same post-training, 70B", emptyList()),
        )
        "pi" -> listOf(
            ModelInfo(
                "default", "pi default", "Runs the model configured in pi (`pi` settings)",
                listOf("minimal", "low", "medium", "high", "xhigh", "max"),
            ),
        )
        "opencode" -> listOf(
            ModelInfo("opencode/big-pickle", "Big Pickle", "OpenCode Zen's flagship coding model", emptyList()),
            ModelInfo("opencode/mimo-v2.5-free", "MiMo V2.5 Free", "Free tier on OpenCode Zen", emptyList()),
            ModelInfo("opencode/hy3-free", "Hy3 Free", "Free tier on OpenCode Zen", listOf("low", "medium", "high")),
        )
        "antigravity" -> listOf(
            ModelInfo("gemini-3.7-flash", "Gemini 3.7 Flash", "Google's fast Gemini model through Antigravity", listOf("low", "medium", "high")),
            ModelInfo("gemini-3.1-pro", "Gemini 3.1 Pro", "Google's most capable Gemini model through Antigravity", listOf("low", "high")),
        )
        "codex" -> listOf(
            ModelInfo("gpt-6-astra", "GPT-6-Astra", "Our most capable model for complex, demanding work.", codexUltraLadder, codexServiceTier),
            ModelInfo("gpt-5.6-sol", "GPT-5.6-Sol", "Frontier reasoning flagship", codexUltraLadder, codexServiceTier),
            ModelInfo("gpt-5.6-terra", "GPT-5.6-Terra", "Deep multi-step agentic work", codexUltraLadder, codexServiceTier),
            ModelInfo("gpt-5.6-luna", "GPT-5.6-Luna", "Fast frontier model", codexMaxLadder, codexServiceTier),
            ModelInfo("gpt-daybreak-blue-latest", "Daybreak Blue", "Frontier model for defensive cybersecurity work", codexUltraLadder),
            ModelInfo("gpt-5.5", "GPT-5.5", "Previous generation flagship", codexXhighLadder, codexServiceTier),
            ModelInfo("gpt-5.4", "GPT-5.4", "Reliable general coding", codexXhighLadder, codexServiceTier),
            ModelInfo("gpt-5.4-mini", "GPT-5.4-Mini", "Small, fast and capable", codexXhighLadder, codexServiceTier),
            ModelInfo("gpt-5.3-codex-spark", "GPT-5.3-Codex-Spark", "Ultra-fast lightweight coding", codexXhighLadder, codexServiceTier),
        )
        else -> listOf( // claude-code (mock shares it)
            ModelInfo("claude-fable-5-1", "Fable 5.1", "Most intelligent model for building agents", fullLadder, listOf(claudeContextWindow)),
            ModelInfo("claude-fable-5", "Fable 5", "Previous generation Fable", fullLadder, listOf(claudeContextWindow)),
            ModelInfo("claude-opus-5", "Opus 5", "Powerful model for complex work", fullLadder, listOf(claudeContextWindow, toggle("fastMode", "Fast Mode"))),
            ModelInfo("claude-opus-4-8", "Opus 4.8", "Previous generation Opus", fullLadder, listOf(toggle("fastMode", "Fast Mode"))),
            ModelInfo("claude-opus-4-7", "Opus 4.7", "Older generation Opus", claudeXhighLadder, listOf(toggle("fastMode", "Fast Mode"))),
            ModelInfo("claude-sonnet-5", "Sonnet 5", "Balanced speed and intelligence", claudeXhighLadder, listOf(claudeContextWindow)),
            ModelInfo("claude-haiku-4-5", "Haiku 4.5", "Fastest model for everyday tasks", emptyList(), listOf(toggle("thinking", "Thinking"))),
        )
    }

    fun defaultModel(harness: String): ModelInfo = models(harness).first()

    /** pickers.rs: High when available, then Medium, then the first level. */
    fun defaultReasoning(model: ModelInfo): String? = when {
        model.reasoningLevels.isEmpty() -> null
        "high" in model.reasoningLevels -> "high"
        "medium" in model.reasoningLevels -> "medium"
        else -> model.reasoningLevels.first()
    }

    fun selectedChoice(option: ModelOptionInfo, selectedId: String?): ModelOptionChoiceInfo =
        option.choices.firstOrNull { it.id == selectedId }
            ?: option.choices.firstOrNull { it.id == option.defaultChoice }
            ?: option.choices.firstOrNull()
            ?: ModelOptionChoiceInfo(option.defaultChoice, option.defaultChoice)

    private fun stripped1M(id: String): String? = when {
        id.endsWith("[1m]") -> id.dropLast(4)
        id.endsWith("-1m") -> id.dropLast(3)
        else -> null
    }

    private fun norm(id: String): String = id.filter { it in '0'..'9' || it in 'A'..'Z' || it in 'a'..'z' }.lowercase()

    private fun curatedLabel(id: String, catalog: List<ModelInfo>): String? {
        val idNorm = norm(id)
        catalog.firstOrNull { norm(it.id) == idNorm }?.let { return it.label }
        if (idNorm.isEmpty() || !idNorm.all { it in 'A'..'Z' || it in 'a'..'z' }) return null
        return catalog.firstOrNull { norm(it.id).contains(idNorm) }?.label
    }

    private fun curatedLabel(id: String, harness: String): String? {
        val catalog = if (harness == "claude-code" || harness == "mock") models(harness) else emptyList()
        return curatedLabel(id, catalog)
    }

    fun resolveExisting(modelId: String?, models: List<ModelInfo>): ModelInfo? {
        if (modelId == null) return null
        models.firstOrNull { it.id == modelId }?.let { return it }
        val base = stripped1M(modelId) ?: return null
        return models.firstOrNull { it.id == base }
    }

    fun resolve(modelId: String?, models: List<ModelInfo>, harness: String): ModelInfo {
        if (modelId == null) return models.firstOrNull() ?: defaultModel(harness)
        resolveExisting(modelId, models)?.let { return it }
        return ModelInfo(modelId, curatedLabel(modelId, harness) ?: modelId, null, emptyList())
    }

    fun reasoningLabel(level: String): String = when (level) {
        "minimal" -> "Minimal"
        "low" -> "Low"
        "medium" -> "Medium"
        "high" -> "High"
        "xhigh" -> "X-High"
        "max" -> "Max"
        "ultra" -> "Ultra"
        "ultracode" -> "Ultracode"
        "ultrathink" -> "Ultrathink"
        else -> level.replaceFirstChar { it.uppercase() }
    }

    /** One-line hints for the effort ladder (the special modes deserve explanation). */
    fun effortHint(level: String): String? = when (level) {
        "minimal" -> "Quickest, lightest touch"
        "low" -> "Fastest responses"
        "medium" -> "Balanced speed and depth"
        "high" -> "Thorough reasoning"
        "xhigh" -> "Extended reasoning"
        "max" -> "Maximum reasoning budget"
        "ultra" -> "Highest Codex tier"
        "ultracode" -> "X-High plus the ultracode setting"
        "ultrathink" -> "Deep-thinking prompt mode"
        else -> null
    }

    fun modelLabel(harness: String, modelId: String?): String =
        resolve(modelId, models(harness), harness).label
}
