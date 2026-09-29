package harness.codegraff.android.theme

import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/** Animation kit: timings and curves ported from crates/ui/src/motion.rs (Motion.swift). */
object Motion {
    private val fadeInEasing = CubicBezierEasing(0.16f, 1f, 0.3f, 1f)
    private val quickEasing = CubicBezierEasing(0.25f, 0.1f, 0.25f, 1f)
    private val resizeEasing = CubicBezierEasing(0f, 0f, 0.58f, 1f)
    private val resortEasing = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

    fun <T> fadeIn(): FiniteAnimationSpec<T> = tween(500, easing = fadeInEasing)
    fun <T> fadeQuick(): FiniteAnimationSpec<T> = tween(150, easing = quickEasing)
    fun <T> menuIn(): FiniteAnimationSpec<T> = tween(140, easing = quickEasing)
    fun <T> dialogIn(): FiniteAnimationSpec<T> = tween(180, easing = quickEasing)
    fun <T> resize(): FiniteAnimationSpec<T> = tween(200, easing = resizeEasing)
    fun <T> collapse(): FiniteAnimationSpec<T> = tween(180, easing = resizeEasing)
    fun <T> resort(): FiniteAnimationSpec<T> = tween(260, easing = resortEasing)

    /** WorkingIndicator wave period (GRADIENT_SPIN), in milliseconds. */
    const val GRADIENT_SPIN_MS = 750
    const val HARNESS_PULSE_MS = 2400

    /** WorkingIndicator flavour words (transcript.rs:795), rotated every 7s, seeded per chat. */
    val flavourWords = listOf(
        "Harnessing",
        "Thinking", "Pondering", "Scheming", "Brewing", "Weaving", "Tinkering",
        "Musing", "Composing", "Sifting", "Untangling", "Distilling", "Sketching",
        "Plotting", "Riffing", "Combobulating", "Percolating", "Marinating",
        "Noodling", "Puzzling", "Conjuring",
    )
    const val FLAVOUR_ROTATE_SECS = 7L

    fun flavourSeed(chatId: String): ULong = fnv1a(chatId)

    fun flavourWord(seed: ULong, elapsedSecs: Long): String {
        val step = (maxOf(0L, elapsedSecs) / FLAVOUR_ROTATE_SECS).toULong()
        return flavourWords[((seed + step) % flavourWords.size.toULong()).toInt()]
    }

    fun formatElapsed(secs: Long): String {
        val s = maxOf(0L, secs)
        return if (s < 60) "${s}s" else "${s / 60}m ${s % 60}s"
    }
}

/** True when the person turned animations off (Remove animations), the analogue of Reduce Motion. */
@Composable
fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember {
        Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}
