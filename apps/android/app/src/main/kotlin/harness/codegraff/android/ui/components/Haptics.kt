package harness.codegraff.android.ui.components

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/** The taps the SwiftUI app makes with `UIImpactFeedbackGenerator` and `UISelectionFeedbackGenerator`. */
class Haptics(private val view: View) {
    /** A light impact: sending, opening the switcher, jumping to the latest message. */
    fun light() { view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP) }

    /** A medium impact: stopping a run. */
    fun medium() { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }

    /** A selection change: picking a row in a picker sheet. */
    fun selection() {
        view.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= 34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK,
        )
    }
}

@Composable
fun rememberHaptics(): Haptics {
    val view = LocalView.current
    return remember(view) { Haptics(view) }
}
