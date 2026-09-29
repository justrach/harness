package harness.codegraff.android.perf

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.floor

/**
 * The anonymous report the apps can send when someone turns sharing on. Numbers and fixed names only: no chat
 * content, account, device or session identifiers. [launchId] is random per process, so the reports of one
 * launch can be joined on the server but never tied to a person or to the next launch.
 * `apps/parity/vectors/perf-report.json` pins the JSON; the iOS app builds the same shape.
 */
data class PerfReport(
    val launchId: String,
    val platform: String,
    val appVersion: String,
    val osVersion: String,
    val device: String,
    val build: String,
    val refreshHz: Int,
    val startupMs: Long?,
    /** "frame" (Android) or "turn" (iOS main run loop turn): the two are not the same measure. */
    val frameKind: String,
    val frames: Frames,
    val thermal: String,
    val lowPower: Boolean,
    val memoryMb: Int,
    val spans: List<SpanStat>,
) {
    data class Frames(val total: Long, val slow: Long, val frozen: Long, val p50: Double, val p95: Double, val worst: Double)

    fun toJson(): JSONObject = JSONObject().apply {
        put("schema", SCHEMA)
        put("launchId", launchId)
        put("platform", platform)
        put("appVersion", appVersion)
        put("osVersion", osVersion)
        put("device", device.take(MAX_DEVICE_LENGTH))
        put("build", build)
        put("refreshHz", refreshHz)
        put("startupMs", startupMs ?: JSONObject.NULL)
        put("frameKind", frameKind)
        put("frames", JSONObject().apply {
            put("total", frames.total)
            put("slow", frames.slow)
            put("frozen", frames.frozen)
            put("p50", round1(frames.p50))
            put("p95", round1(frames.p95))
            put("worst", round1(frames.worst))
        })
        put("thermal", thermal)
        put("lowPower", lowPower)
        put("memoryMb", memoryMb)
        // Only the operations both apps define: a name minted somewhere else can never carry content out.
        put("spans", JSONArray().apply {
            for (s in spans) if (s.name in PerfSpan.budgetsMs) put(JSONObject().apply {
                put("name", s.name)
                put("count", s.count)
                put("p50", round1(s.p50))
                put("p95", round1(s.p95))
                put("max", round1(s.max))
                put("totalMs", round1(s.totalMs))
                put("overBudget", s.overBudget)
            })
        })
    }

    companion object {
        const val SCHEMA = 1
        const val MAX_DEVICE_LENGTH = 40

        private fun round1(x: Double) = floor(x * 10 + 0.5) / 10
    }
}
