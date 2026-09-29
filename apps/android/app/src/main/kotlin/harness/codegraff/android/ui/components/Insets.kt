package harness.codegraff.android.ui.components

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp

/** Height of the status bar (or cutout) the floating bars must clear. */
@Composable
fun statusBarHeight(): Dp = with(LocalDensity.current) { WindowInsets.statusBars.getTop(this).toDp() }

/** Height of the gesture or navigation bar the bottom controls must clear. */
@Composable
fun navigationBarHeight(): Dp = with(LocalDensity.current) { WindowInsets.navigationBars.getBottom(this).toDp() }
