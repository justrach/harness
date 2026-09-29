package harness.codegraff.android.perf

import android.app.Activity
import android.content.Context
import android.os.PowerManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.os.Trace
import android.util.Log
import android.view.FrameMetrics
import android.view.ViewTreeObserver
import android.view.Window
import androidx.compose.runtime.withFrameNanos
import java.util.concurrent.ConcurrentHashMap

/**
 * The operation names both apps report, so a number on one platform can be compared with the same number
 * on the other. `apps/parity/perf-contract.json` pins these and the budgets; ParityTest checks them.
 */
object PerfSpan {
    const val StartupFirstFrame = "startup.firstFrame"
    const val NavigationOpen = "nav.open"
    const val TranscriptRows = "transcript.rows"
    const val MarkdownParse = "markdown.parse"
    const val HomeGroup = "home.group"
    const val SendApply = "send.apply"
    const val MainStall = "main.stall"

    /** Milliseconds an operation may take before it counts as slow (one 60 Hz frame is 16.7). */
    val budgetsMs: Map<String, Double> = mapOf(
        StartupFirstFrame to 1000.0,
        NavigationOpen to 100.0,
        TranscriptRows to 8.0,
        MarkdownParse to 4.0,
        HomeGroup to 4.0,
        SendApply to 8.0,
        MainStall to 100.0,
    )
}

data class MemorySnapshot(val javaUsedMb: Long, val javaMaxMb: Long, val nativeMb: Long, val gcCount: Long, val gcTimeMs: Long)

/**
 * Local performance monitor. It answers "what is slow" without leaving the device: operation timings
 * against budgets, per-frame stage costs, main-thread stalls (which frame stats miss when nothing is
 * drawing), startup and memory. Nothing is uploaded; Settings shows it and can copy a report.
 * Operations also show up as sections in a Perfetto trace.
 */
object Perf {
    private const val TAG = "HarnessPerf"
    /** How often the main thread is checked while frames are being drawn, and while nothing is (one wake a second). */
    private const val STALL_ACTIVE_MS = 100L
    private const val STALL_IDLE_MS = 1000L
    private const val STALL_MIN_MS = 50L
    private const val STRESS_RECHECK_MS = 30_000L
    private const val LOG_EVERY_MS = 1000L
    private const val STALE_INTERACTION_MS = 5000.0

    val recorder = PerfRecorder()
    val frames = FrameTally()

    /** Samples since the last upload, in the ranges the server merges. Fed by [record] and every frame. */
    val histograms = PerfHistograms()

    @Volatile var startupMs: Long? = null
        private set
    @Volatile var refreshHz: Float = 60f
        private set

    private val lastLogged = ConcurrentHashMap<String, Long>()

    fun record(name: String, ms: Double) {
        val budget = PerfSpan.budgetsMs[name] ?: Double.MAX_VALUE
        recorder.record(name, ms, budget)
        PerfMetric.forSpan[name]?.let { histograms.add(it, ms) }
        if (ms > budget) {
            // One line a second per operation: a persistent overrun must not turn into constant logging.
            val now = SystemClock.elapsedRealtime()
            val previous = lastLogged[name]
            if (previous == null || now - previous >= LOG_EVERY_MS) {
                lastLogged[name] = now
                Log.w(TAG, "$name took ${"%.1f".format(ms)} ms (budget ${budget.toLong()} ms)")
            }
        }
    }

    inline fun <T> measure(name: String, block: () -> T): T {
        val start = System.nanoTime()
        Trace.beginSection(name)
        try {
            return block()
        } finally {
            Trace.endSection()
            record(name, (System.nanoTime() - start) / 1e6)
        }
    }

    // Interactions: a tap starts one, the destination finishes it a frame after it is composed.

    private val started = ConcurrentHashMap<String, Long>()

    fun startInteraction(name: String) {
        started[name] = System.nanoTime()
    }

    /** Call from an effect in the destination; records tap to the frame after its first composition. */
    suspend fun finishInteraction(name: String) {
        val start = started.remove(name) ?: return
        withFrameNanos { }
        val ms = (System.nanoTime() - start) / 1e6
        // A tap that never showed a new page (the same row picked again) leaves its start behind; that is not a slow open.
        if (ms < STALE_INTERACTION_MS) record(name, ms)
    }

    // Startup

    private var created = false

    /** True the first time an activity is created in this process, so a rotation or return is not counted as a launch. */
    fun isColdStart(): Boolean = !created.also { created = true }

    fun watchFirstFrame(activity: Activity) {
        val decor = activity.window.decorView
        decor.viewTreeObserver.addOnDrawListener(object : ViewTreeObserver.OnDrawListener {
            private var done = false
            override fun onDraw() {
                if (done) return
                done = true
                val ms = SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime()
                startupMs = ms
                record(PerfSpan.StartupFirstFrame, ms.toDouble())
                activity.reportFullyDrawn()
                // A listener cannot remove itself while the draw pass is dispatching.
                decor.post { decor.viewTreeObserver.removeOnDrawListener(this) }
            }
        })
    }

    // Frames and stalls, while the app is in front.

    private val frameThread by lazy { HandlerThread("harness-frames").apply { start() } }
    private val mainHandler = Handler(Looper.getMainLooper())
    private var listener: Window.OnFrameMetricsAvailableListener? = null
    private var watching = false
    private var expectedAt = 0L
    private var appContext: Context? = null
    private var stressCheckedAt = 0L
    private var lastFrameCount = -1L

    /** The device is hot or saving power: the monitor's own background work should stay out of the way. */
    private fun stressed(): Boolean = appContext?.let { !PerfPolicy.deviceIsCalm(batterySaver(it), thermalLabel(it)) } ?: false

    private val stallTick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            val late = now - expectedAt
            if (late >= STALL_MIN_MS) record(PerfSpan.MainStall, late.toDouble())
            if (!watching) return
            if (now - stressCheckedAt >= STRESS_RECHECK_MS) {
                stressCheckedAt = now
                // Stop the timer altogether; the next resume looks again.
                if (stressed()) { watching = false; return }
            }
            // Check often while the screen is animating (it is waking anyway), about once a second when it is still,
            // so an idle app is not woken ten times a second for the monitor.
            val drawn = frames.frameCount()
            val active = drawn != lastFrameCount
            lastFrameCount = drawn
            schedule(if (active) STALL_ACTIVE_MS else STALL_IDLE_MS)
        }
    }

    private fun schedule(periodMs: Long) {
        expectedAt = SystemClock.uptimeMillis() + periodMs
        mainHandler.postDelayed(stallTick, periodMs)
    }

    @Suppress("DEPRECATION")
    fun resume(activity: Activity) {
        refreshHz = activity.windowManager.defaultDisplay.refreshRate.takeIf { it > 0f } ?: 60f
        val budgetMs = 1000.0 / refreshHz
        val stages = DoubleArray(FrameStage.entries.size)
        val l = Window.OnFrameMetricsAvailableListener { _, metrics, _ ->
            // The first draw is startup, counted on its own.
            if (metrics.getMetric(FrameMetrics.FIRST_DRAW_FRAME) == 1L) return@OnFrameMetricsAvailableListener
            fun ms(metric: Int) = metrics.getMetric(metric) / 1e6
            stages[FrameStage.Input.ordinal] = ms(FrameMetrics.INPUT_HANDLING_DURATION)
            stages[FrameStage.Animation.ordinal] = ms(FrameMetrics.ANIMATION_DURATION)
            stages[FrameStage.Layout.ordinal] = ms(FrameMetrics.LAYOUT_MEASURE_DURATION)
            stages[FrameStage.Draw.ordinal] = ms(FrameMetrics.DRAW_DURATION)
            stages[FrameStage.Sync.ordinal] = ms(FrameMetrics.SYNC_DURATION)
            stages[FrameStage.Commands.ordinal] = ms(FrameMetrics.COMMAND_ISSUE_DURATION)
            stages[FrameStage.Swap.ordinal] = ms(FrameMetrics.SWAP_BUFFERS_DURATION)
            // From Android 12 the system says how long this frame had (a pipelined frame may have more than one
            // vsync); judging against one refresh period would call nearly every frame slow.
            val deadlineMs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) ms(FrameMetrics.DEADLINE) else 0.0
            val totalMs = ms(FrameMetrics.TOTAL_DURATION)
            frames.add(totalMs, stages, if (deadlineMs > 0) deadlineMs else budgetMs)
            histograms.add(PerfMetric.FrameCost, totalMs)
        }
        listener = l
        activity.window.addOnFrameMetricsAvailableListener(l, Handler(frameThread.looper))
        appContext = activity.applicationContext
        stressCheckedAt = SystemClock.uptimeMillis()
        lastFrameCount = -1
        watching = !stressed()
        if (watching) schedule(STALL_ACTIVE_MS)
    }

    fun pause(activity: Activity) {
        watching = false
        mainHandler.removeCallbacks(stallTick)
        listener?.let { activity.window.removeOnFrameMetricsAvailableListener(it) }
        listener = null
    }

    fun memory(): MemorySnapshot {
        val rt = Runtime.getRuntime()
        fun stat(key: String) = Debug.getRuntimeStat(key)?.toLongOrNull() ?: 0L
        return MemorySnapshot(
            javaUsedMb = (rt.totalMemory() - rt.freeMemory()) shr 20,
            javaMaxMb = rt.maxMemory() shr 20,
            nativeMb = Debug.getNativeHeapAllocatedSize() shr 20,
            gcCount = stat("art.gc.gc-count"),
            gcTimeMs = stat("art.gc.gc-time"),
        )
    }

    /** How hot the device is: a throttled CPU explains slowness no code change will fix. */
    fun thermalLabel(context: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "Unknown"
        return when (context.getSystemService(PowerManager::class.java)?.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "None"
            PowerManager.THERMAL_STATUS_LIGHT -> "Light"
            PowerManager.THERMAL_STATUS_MODERATE -> "Moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "Severe"
            null -> "Unknown"
            else -> "Critical"
        }
    }

    fun batterySaver(context: Context): Boolean = context.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true

    fun reset() {
        recorder.reset()
        frames.reset()
    }

    /** Plain text a user can paste into an issue: numbers only, no chat content, names or identifiers. */
    fun report(context: Context, version: String): String = buildString {
        val f = frames.snapshot()
        val m = memory()
        appendLine("Harness performance · Android $version · ${Build.MODEL} · API ${Build.VERSION.SDK_INT} · ${refreshHz.toInt()} Hz")
        appendLine("Startup: ${startupMs?.let { "$it ms to first frame" } ?: "not measured this run"}")
        appendLine("Frames: ${f.frames}, slow ${f.slow} (${"%.1f".format(f.slowPercent)}%), frozen ${f.frozen}; median ${"%.1f".format(f.p50)} ms, 95th ${"%.1f".format(f.p95)} ms, worst ${"%.0f".format(f.worst)} ms")
        if (f.slowFramesBlamedOn.isNotEmpty()) {
            appendLine("Slow frames spend longest in: " + f.slowFramesBlamedOn.joinToString { "${it.first.label} ${it.second}" })
        }
        appendLine("Memory: Java ${m.javaUsedMb}/${m.javaMaxMb} MB, native ${m.nativeMb} MB, ${m.gcCount} collections (${m.gcTimeMs} ms)")
        appendLine("Device: thermal ${thermalLabel(context)}${if (batterySaver(context)) " · Battery Saver" else ""}")
        appendLine("Operations (median / 95th / worst ms, over budget):")
        for (s in recorder.stats()) {
            appendLine("  ${s.name} ×${s.count}: ${"%.1f".format(s.p50)} / ${"%.1f".format(s.p95)} / ${"%.1f".format(s.max)}, ${s.overBudget} over")
        }
    }
}
