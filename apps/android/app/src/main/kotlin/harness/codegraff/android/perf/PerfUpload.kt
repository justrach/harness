package harness.codegraff.android.perf

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Decides when a report may go out. The rules are pinned in `apps/parity/vectors/perf-report.json`: an
 * endpoint must exist, sharing must be on, the session must have drawn enough frames to mean something, at most
 * one report goes out per interval, and a failed post does not start the wait.
 */
class PerfUploader(
    private val endpoint: String?,
    private val enabled: () -> Boolean,
    private val minFrames: Long = MIN_FRAMES,
    private val minIntervalMs: Long = MIN_INTERVAL_MS,
    private val now: () -> Long = System::currentTimeMillis,
    private val post: (endpoint: String, body: String) -> Boolean,
) {
    private var lastSentAt: Long? = null

    /** True when a report was sent. */
    @Synchronized
    fun flush(report: PerfReport): Boolean {
        val url = endpoint ?: return false
        if (!enabled()) return false
        if (report.frames.total < minFrames) return false
        val t = now()
        lastSentAt?.let { if (t - it < minIntervalMs) return false }
        val ok = post(url, report.toJson().toString())
        if (ok) lastSentAt = t
        return ok
    }

    companion object {
        const val MIN_FRAMES = 60L
        const val MIN_INTERVAL_MS = 10 * 60_000L
    }
}

/** A plain JSON POST: no cookies, no credentials, no redirects, and only over https (loopback may use http for tests). */
object PerfTransport {
    fun isAllowed(endpoint: String): Boolean {
        val url = runCatching { URL(endpoint) }.getOrNull() ?: return false
        return url.protocol == "https" || (url.protocol == "http" && url.host in setOf("localhost", "127.0.0.1"))
    }

    fun post(endpoint: String, body: String): Boolean {
        if (!isAllowed(endpoint)) return false
        return runCatching {
            val c = URL(endpoint).openConnection() as HttpURLConnection
            try {
                c.requestMethod = "POST"
                c.connectTimeout = TIMEOUT_MS
                c.readTimeout = TIMEOUT_MS
                c.useCaches = false
                c.instanceFollowRedirects = false
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(body.toByteArray()) }
                c.responseCode in 200..299
            } finally {
                c.disconnect()
            }
        }.getOrDefault(false)
    }

    private const val TIMEOUT_MS = 10_000
}

/** Whether anonymous reports are sent. On unless the person turns it off in Settings, and only when there is somewhere to send. */
object PerfSharing {
    private const val KEY = "share-performance"

    /** Pinned in `apps/parity/vectors/perf-report.json`. */
    const val DEFAULT_ENABLED = true
    private var prefs: SharedPreferences? = null

    /** Where reports go. Unset until the backend is agreed; with no endpoint nothing is offered and nothing is sent. */
    val endpoint: String? = null

    val available: Boolean get() = endpoint != null

    var enabled by mutableStateOf(DEFAULT_ENABLED)
        private set

    fun init(context: Context) {
        val p = context.getSharedPreferences("harness-ui", Context.MODE_PRIVATE)
        prefs = p
        enabled = p.getBoolean(KEY, DEFAULT_ENABLED)
    }

    fun set(on: Boolean) {
        enabled = on
        prefs?.edit()?.putBoolean(KEY, on)?.apply()
    }

    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "harness-perf-upload").apply { isDaemon = true } }
    private val uploader by lazy { PerfUploader(endpoint, enabled = { enabled }, post = PerfTransport::post) }

    /** Called when the app goes to the background. Cheap when sharing is off: nothing is built. */
    fun flush(context: Context) {
        if (!available || !enabled) return
        val report = Perf.buildReport(context)
        worker.execute { uploader.flush(report) }
    }
}

private val launchId: String = UUID.randomUUID().toString()

internal fun Perf.buildReport(context: Context): PerfReport {
    val f = frames.snapshot()
    val m = memory()
    val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "?"
    val debuggable = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    return PerfReport(
        launchId = launchId,
        platform = "android",
        appVersion = version,
        osVersion = Build.VERSION.SDK_INT.toString(),
        device = Build.MODEL,
        build = if (debuggable) "debug" else "release",
        refreshHz = refreshHz.toInt(),
        startupMs = startupMs,
        frameKind = "frame",
        frames = PerfReport.Frames(f.frames, f.slow, f.frozen, f.p50, f.p95, f.worst),
        thermal = thermalLabel(context),
        lowPower = batterySaver(context),
        memoryMb = (m.javaUsedMb + m.nativeMb).toInt(),
        spans = recorder.stats(),
    )
}
