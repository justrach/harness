package harness.codegraff.android.perf

import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Decides when a batch may go out. The rules are pinned in `apps/parity/vectors/perf-stats.json`: an endpoint must
 * exist, sharing must be on, the window must have samples, at most one attempt goes out per interval, and samples
 * recorded while nothing can be sent are dropped rather than held for later.
 */
class PerfUploader(
    private val endpoint: String?,
    private val enabled: () -> Boolean,
    private val source: PerfHistograms,
    private val meta: () -> PerfBatchMeta,
    private val minIntervalMs: Long = MIN_INTERVAL_MS,
    private val now: () -> Long = System::currentTimeMillis,
    /** Posts the body and returns the HTTP status, or 0 when the connection failed. */
    private val post: (endpoint: String, body: String) -> Int,
) {
    private var lastAttemptAt: Long? = null
    private var stopped = false

    /**
     * True when a batch was sent. A 2xx is sent. 429 and other 4xx keep the samples and start the wait. 400, 413 and
     * 415 mean the batch itself is wrong, so it is dropped and sending stops for the rest of the launch. 5xx and a
     * failed connection keep the samples and start no wait: they are tried again at the next chance.
     */
    @Synchronized
    fun flush(): Boolean {
        val t = now()
        lastAttemptAt?.let { if (t - it < minIntervalMs) return false }
        val window = source.take() ?: return false
        val url = endpoint
        if (url == null || !enabled() || stopped) return false
        val status = post(url, PerfStatsBatch(meta(), window).toJson().toString())
        return when (status) {
            in 200..299 -> { lastAttemptAt = t; true }
            400, 413, 415 -> { stopped = true; false }
            in 400..499 -> { lastAttemptAt = t; source.restore(window); false }
            else -> { source.restore(window); false }
        }
    }

    companion object {
        const val MIN_INTERVAL_MS = 10 * 60_000L
    }
}

/** A plain JSON POST: no cookies, no credentials, no redirects, and only over https (loopback may use http for tests). */
object PerfTransport {
    fun isAllowed(endpoint: String): Boolean {
        val url = runCatching { URL(endpoint) }.getOrNull() ?: return false
        return url.protocol == "https" || (url.protocol == "http" && url.host in setOf("localhost", "127.0.0.1"))
    }

    /** The HTTP status, or 0 when nothing was sent or the connection failed. */
    fun post(endpoint: String, body: String): Int {
        if (!isAllowed(endpoint)) return 0
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
                c.responseCode
            } finally {
                c.disconnect()
            }
        }.getOrDefault(0)
    }

    private const val TIMEOUT_MS = 10_000
}

/** Whether anonymous reports are sent. On unless the person turns it off in Settings, and only when there is somewhere to send. */
object PerfSharing {
    private const val KEY = "share-performance"

    /** Pinned in `apps/parity/vectors/perf-stats.json`. */
    const val DEFAULT_ENABLED = true

    private var prefs: SharedPreferences? = null

    /** Where reports go. Unset until the backend is agreed; with no endpoint nothing is offered and nothing is sent. */
    val endpoint: String? = null

    val available: Boolean get() = endpoint != null

    /** What the Settings switch shows. Uploads read the stored value themselves, on their own thread. */
    var enabled by mutableStateOf(DEFAULT_ENABLED)
        private set

    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "harness-perf-upload").apply { isDaemon = true } }
    private val uploader by lazy {
        PerfUploader(endpoint, enabled = ::storedEnabled, source = Perf.histograms, meta = { batchMeta() }, post = PerfTransport::post)
    }
    private var appContext: Context? = null
    private val installId: String = UUID.randomUUID().toString()

    private fun storedEnabled(): Boolean = prefs?.getBoolean(KEY, DEFAULT_ENABLED) ?: DEFAULT_ENABLED

    /** Does no file reading on the caller's thread: launch must not wait on a preferences file for this. */
    fun init(context: Context) {
        val app = context.applicationContext
        appContext = app
        worker.execute {
            val p = app.getSharedPreferences("harness-ui", Context.MODE_PRIVATE)
            prefs = p
            val stored = p.getBoolean(KEY, DEFAULT_ENABLED)
            Handler(Looper.getMainLooper()).post { enabled = stored }
        }
    }

    fun set(on: Boolean) {
        enabled = on
        worker.execute { prefs?.edit()?.putBoolean(KEY, on)?.apply() }
    }

    /**
     * Called when the app goes to the background. Nothing runs on the caller's thread but queuing the work. A batch is
     * only built, and only sent, when sharing is on, this is not a debuggable build, the device is neither hot nor
     * saving power, and the network is not metered: a radio waking on mobile data costs more battery than the batch
     * is worth. Samples that could not go now stay for the next attempt; samples recorded while sharing is off are
     * dropped and never sent later.
     */
    fun flush(context: Context) {
        if (!available) return
        val app = context.applicationContext
        worker.execute {
            if (!storedEnabled() || isDebuggable(app)) { Perf.histograms.take(); return@execute }
            if (!PerfPolicy.deviceIsCalm(Perf.batterySaver(app), Perf.thermalLabel(app))) return@execute
            if (isMetered(app)) return@execute
            uploader.flush()
        }
    }

    private fun isDebuggable(context: Context) = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    private fun batchMeta(): PerfBatchMeta {
        val context = requireNotNull(appContext)
        val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "?"
        val arch = when (Build.SUPPORTED_ABIS.firstOrNull()) {
            "arm64-v8a" -> "aarch64"
            "x86_64" -> "x86_64"
            else -> "other"
        }
        return PerfBatchMeta(installId, "android", arch, version, Build.VERSION.SDK_INT.toString(), Build.MODEL, Perf.refreshHz.toInt())
    }

    /** Unknown counts as metered: when in doubt, do not wake the radio. */
    private fun isMetered(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return true
        val caps = runCatching { cm.getNetworkCapabilities(cm.activeNetwork) }.getOrNull() ?: return true
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
}
