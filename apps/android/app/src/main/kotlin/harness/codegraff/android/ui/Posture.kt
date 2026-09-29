package harness.codegraff.android.ui

import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.runtime.Composable

/**
 * The top edge, in window pixels, of a horizontal fold when the device is in
 * tabletop posture (half-open, screen split into a top and bottom half); null in
 * every other posture. Anything above it is the half the person looks at,
 * anything below it is the half they touch.
 */
/** Height, in pixels, of content that starts at [contentTop] and must end at the fold. Never negative. */
fun heightAboveHinge(hingeTop: Float, contentTop: Float): Float = (hingeTop - contentTop).coerceAtLeast(0f)

@Composable
fun tabletopHingeTop(): Float? {
    val posture = currentWindowAdaptiveInfo().windowPosture
    if (!posture.isTabletop) return null
    return posture.hingeList.firstOrNull { it.isSeparating && !it.isVertical }?.bounds?.top
}
