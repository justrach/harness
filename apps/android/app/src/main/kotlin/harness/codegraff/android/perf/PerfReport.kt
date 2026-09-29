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
        put("device", device.filter { it in ALLOWED_DEVICE_CHARS }.take(MAX_DEVICE_LENGTH))
        put("build", build)
        put("refreshHz", refreshHz.coerceIn(MIN_REFRESH_HZ, MAX_REFRESH_HZ))
        put("startupMs", startupMs ?: JSONObject.NULL)
        put("frameKind", frameKind)
        // Values the server would refuse are made to fit instead: one 90 second stall must not get a launch's
        // reports rejected for good.
        val total = frames.total.coerceIn(0, MAX_FRAMES)
        put("frames", JSONObject().apply {
            put("total", total)
            put("slow", frames.slow.coerceIn(0, total))
            put("frozen", frames.frozen.coerceIn(0, total))
            put("p50", ms(frames.p50))
            put("p95", ms(frames.p95))
            put("worst", ms(frames.worst))
        })
        put("thermal", thermal)
        put("lowPower", lowPower)
        put("memoryMb", memoryMb)
        // Only the operations both apps define: a name minted somewhere else can never carry content out.
        put("spans", JSONArray().apply {
            for (s in spans) if (s.name in PerfSpan.budgetsMs) put(JSONObject().apply {
                put("name", s.name)
                put("count", s.count)
                put("p50", ms(s.p50))
                put("p95", ms(s.p95))
                put("max", ms(s.max))
                put("totalMs", round1(s.totalMs))
                put("overBudget", s.overBudget)
            })
        })
    }

    companion object {
        const val SCHEMA = 1
        const val MAX_DEVICE_LENGTH = 40
        const val MAX_MS = 60_000.0
        const val MAX_FRAMES = 9_999_999L
        const val MIN_REFRESH_HZ = 24
        const val MAX_REFRESH_HZ = 240

        /** What the server accepts in a device model: letters, digits and ` ,._()-`. */
        private val ALLOWED_DEVICE_CHARS: Set<Char> = (('a'..'z') + ('A'..'Z') + ('0'..'9') + " ,._()-".toList()).toSet()

        private fun ms(x: Double) = round1(minOf(x, MAX_MS))

        private fun round1(x: Double) = floor(x * 10 + 0.5) / 10
    }
}
