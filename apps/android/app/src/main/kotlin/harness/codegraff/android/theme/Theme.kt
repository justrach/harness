package harness.codegraff.android.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.R

/** Extra paint Material 3 has no slot for (success, warning) plus the raw palette. */
val LocalPalette = staticCompositionLocalOf { HarnessDark }

object Theme {
    val palette: HarnessPalette
        @Composable get() = LocalPalette.current

    val bubbleRadius = 22.dp
    val panelRadius = 12.dp
    val spaceXS = 4.dp
    val spaceSM = 8.dp
    val spaceMD = 12.dp
    val spaceLG = 16.dp

    /** Widest a transcript or composer column grows, so lines stay readable on tablets and unfolded foldables. */
    val readingWidth = 720.dp
}

val GeistSans = FontFamily(
    Font(R.font.geist_regular, FontWeight.Normal),
    Font(R.font.geist_medium, FontWeight.Medium),
    Font(R.font.geist_semibold, FontWeight.SemiBold),
)

val GeistMono = FontFamily(Font(R.font.geist_mono, FontWeight.Normal))

/** The Material 3 type scale, set in Geist. */
private fun harnessTypography(): Typography {
    val base = Typography()
    fun TextStyle.geist() = copy(fontFamily = GeistSans)
    return base.copy(
        displayLarge = base.displayLarge.geist(), displayMedium = base.displayMedium.geist(),
        displaySmall = base.displaySmall.geist(), headlineLarge = base.headlineLarge.geist(),
        headlineMedium = base.headlineMedium.geist(), headlineSmall = base.headlineSmall.geist(),
        titleLarge = base.titleLarge.geist(), titleMedium = base.titleMedium.geist(),
        titleSmall = base.titleSmall.geist(), bodyLarge = base.bodyLarge.geist(),
        bodyMedium = base.bodyMedium.geist(), bodySmall = base.bodySmall.geist(),
        labelLarge = base.labelLarge.geist(), labelMedium = base.labelMedium.geist(),
        labelSmall = base.labelSmall.geist(),
    )
}

/**
 * Maps the shared Harness palette onto every Material 3 color role so stock
 * components (top bars, chips, list items, text fields) paint correctly with no
 * per-component overrides. Containers are the accent laid over the surface, the
 * way M3 derives them from a seed.
 */
internal fun HarnessPalette.toColorScheme(): ColorScheme {
    val accentWash = accent.copy(alpha = if (isDark) 0.22f else 0.14f).compositeOver(bg)
    val selectedWash = accent.copy(alpha = if (isDark) 0.16f else 0.10f).compositeOver(bg)
    val high = surfaceRaised
    val highest = text.copy(alpha = 0.06f).compositeOver(surfaceRaised)
    val base = if (isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = accent, onPrimary = accentOn,
        primaryContainer = accentWash, onPrimaryContainer = text,
        secondary = textMuted, onSecondary = bg,
        secondaryContainer = selectedWash, onSecondaryContainer = text,
        tertiary = warning, onTertiary = bg,
        tertiaryContainer = warning.copy(alpha = 0.18f).compositeOver(bg), onTertiaryContainer = text,
        background = bg, onBackground = text,
        surface = bg, onSurface = text,
        surfaceVariant = surface, onSurfaceVariant = textMuted,
        surfaceTint = accent,
        inverseSurface = text, inverseOnSurface = bg, inversePrimary = accent,
        error = danger, onError = Color.White,
        errorContainer = danger.copy(alpha = 0.16f).compositeOver(bg), onErrorContainer = text,
        outline = borderStrong, outlineVariant = border,
        scrim = Color.Black,
        surfaceBright = bg, surfaceDim = surface,
        surfaceContainerLowest = bg, surfaceContainerLow = surface,
        surfaceContainer = surface, surfaceContainerHigh = high, surfaceContainerHighest = highest,
    )
}

@Composable
fun HarnessTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val palette = if (dark) HarnessDark else HarnessLight
    CompositionLocalProvider(LocalPalette provides palette) {
        MaterialTheme(
            colorScheme = palette.toColorScheme(),
            typography = harnessTypography(),
            content = content,
        )
    }
}
