package harness.codegraff.android.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.R

val LocalPalette = staticCompositionLocalOf { HarnessDark }

/** Paint and layout tokens, mirroring iOS `Theme`. Numbers drive layout; colors are paint. */
object Theme {
    val palette: HarnessPalette
        @Composable get() = LocalPalette.current

    val bubbleRadius = 22.dp
    val panelRadius = 10.dp
    val controlRadius = 6.dp
    val spaceXS = 4.dp
    val spaceSM = 8.dp
    val spaceMD = 12.dp
    val spaceLG = 16.dp
}

val GeistSans = FontFamily(
    Font(R.font.geist_regular, FontWeight.Normal),
    Font(R.font.geist_medium, FontWeight.Medium),
    Font(R.font.geist_semibold, FontWeight.SemiBold),
)

val GeistMono = FontFamily(Font(R.font.geist_mono, FontWeight.Normal))

object Type {
    val title = TextStyle(fontFamily = GeistSans, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
    val body = TextStyle(fontFamily = GeistSans, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 22.sp)
    val row = TextStyle(fontFamily = GeistSans, fontWeight = FontWeight.Medium, fontSize = 15.sp)
    val caption = TextStyle(fontFamily = GeistSans, fontWeight = FontWeight.Normal, fontSize = 12.sp)
    val mono = TextStyle(fontFamily = GeistMono, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 18.sp)
}

@Composable
fun HarnessTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val p = if (dark) HarnessDark else HarnessLight
    val scheme = if (dark) {
        darkColorScheme(
            primary = p.accent, onPrimary = p.accentOn, background = p.bg, onBackground = p.text,
            surface = p.surface, onSurface = p.text, error = p.danger,
        )
    } else {
        lightColorScheme(
            primary = p.accent, onPrimary = p.accentOn, background = p.bg, onBackground = p.text,
            surface = p.surface, onSurface = p.text, error = p.danger,
        )
    }
    CompositionLocalProvider(LocalPalette provides p) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
