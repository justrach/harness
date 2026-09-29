package harness.codegraff.android.theme

import android.app.Activity
import android.content.Context
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import harness.codegraff.android.R
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/**
 * The roles the phone paints, resolved from one variant exactly the way the
 * desktop's `Theme::from_variant` resolves them (ThemePalette in ThemeStore.swift).
 */
class HarnessPalette(variant: ThemeVariant) {
    private val colors = variant.colors
    private val accentColors = variant.accent
    val isDark: Boolean = variant.appearance.isDark
    val bg = colors.background
    val surface = colors.shell
    val surfaceRaised = colors.raised
    val surfaceDialog = colors.dialog
    val elementHover = colors.hover
    val elementActive = colors.active
    val border = colors.border
    val borderStrong = colors.borderStrong
    val text = colors.text
    val textMuted = colors.textMuted
    val textFaint = colors.textFaint
    val accent = accentColors.primary
    val accentStrong = accentColors.strong
    val accentOn = accentColors.on
    val danger = colors.danger
    val dangerSoft = colors.dangerMuted
    val warning = colors.warning
    val statusWorking = accentColors.activity
    val statusCompleted = colors.success
    val inlineCodeText = accentColors.primary
    val inlineCodeWash = accentColors.wash
    val tokenKeyword = variant.syntax["keyword"] ?: accent
    val tokenString = variant.syntax["string"] ?: accent
    val tokenNumber = variant.syntax["number"] ?: accent

    /** Translucent **fill** ink for washes, chips and pressed states: white on dark themes, black on light ones. */
    fun ink(alpha: Float): Color = if (isDark) Color.White.copy(alpha) else Color.Black.copy(alpha * INK_FILL_SCALE)

    /** Translucent **hairline** ink for borders, dividers and rings; a 1dp line needs more ink on a bright field. */
    fun hairline(alpha: Float): Color =
        if (isDark) Color.White.copy(alpha) else Color.Black.copy(minOf(alpha * INK_HAIRLINE_SCALE, 0.5f))

    /** A project's own color, keyed by its space id: the same project reads the same on every device. */
    fun projectTint(key: String): Color {
        val hue = PROJECT_HUES[projectTintIndex(key)]
        return if (isDark) oklch(0.76, 0.13, hue) else oklch(0.52, 0.16, hue)
    }

    private companion object {
        const val INK_FILL_SCALE = 1.0f
        const val INK_HAIRLINE_SCALE = 1.35f
    }
}

/** Coral, amber, green, teal, sky, indigo, violet, pink. */
private val PROJECT_HUES = doubleArrayOf(25.0, 70.0, 145.0, 185.0, 235.0, 265.0, 300.0, 340.0)

fun projectTintIndex(key: String): Int = (fnv1a(key) % PROJECT_HUES.size.toULong()).toInt()

/** FNV-1a: a hash that is stable across launches. */
fun fnv1a(text: String): ULong {
    var hash = 0xcbf29ce484222325uL
    for (byte in text.encodeToByteArray()) {
        hash = hash xor (byte.toULong() and 0xffuL)
        hash *= 0x100000001b3uL
    }
    return hash
}

/** oklch (CSS notation: L 0..1, C, H degrees) to an sRGB [Color]. */
fun oklch(l: Double, c: Double, hDeg: Double): Color {
    val h = Math.toRadians(hDeg)
    val a = c * cos(h)
    val b = c * sin(h)
    val l_ = l + 0.39633778 * a + 0.21580376 * b
    val m_ = l - 0.105561346 * a - 0.06385417 * b
    val s_ = l - 0.08948418 * a - 1.2914855 * b
    val l3 = l_ * l_ * l_
    val m3 = m_ * m_ * m_
    val s3 = s_ * s_ * s_
    val r = 4.0767417 * l3 - 3.3077116 * m3 + 0.23096993 * s3
    val g = -1.268438 * l3 + 2.6097574 * m3 - 0.3413194 * s3
    val bl = -0.0041960863 * l3 - 0.7034186 * m3 + 1.7076147 * s3
    return Color(gamma(r).toFloat(), gamma(g).toFloat(), gamma(bl).toFloat())
}

private fun gamma(x: Double): Double {
    val v = x.coerceIn(0.0, 1.0)
    return if (v <= 0.0031308) 12.92 * v else 1.055 * v.pow(1.0 / 2.4) - 0.055
}

/**
 * SwiftUI's `.opacity(x)`: scales the color's own alpha. Compose's `copy(alpha = x)` REPLACES it, which
 * is wrong for the theme's translucent border, hover and wash colors.
 */
fun Color.opacity(factor: Float): Color = copy(alpha = alpha * factor)

val LocalThemeStore = staticCompositionLocalOf<ThemeStore> { error("no ThemeStore provided") }
val LocalPalette = compositionLocalOf<HarnessPalette> { error("no palette provided") }

/** Paint and layout tokens, mirroring iOS `Theme`. Numbers drive layout; colors are paint. */
object Theme {
    val palette: HarnessPalette
        @Composable get() = LocalPalette.current

    val bubbleRadius: Dp = 22.dp
    val panelRadius: Dp = 10.dp
    val controlRadius: Dp = 6.dp
    val spaceXS: Dp = 4.dp
    val spaceSM: Dp = 8.dp
    val spaceMD: Dp = 12.dp
    val spaceLG: Dp = 16.dp

    /** Widest a transcript or composer column grows (TranscriptView.maxContentWidth). */
    val readingWidth: Dp = 720.dp
}

@Composable fun ink(alpha: Float): Color = Theme.palette.ink(alpha)

@Composable fun hairline(alpha: Float): Color = Theme.palette.hairline(alpha)

val GeistSans = FontFamily(
    Font(R.font.geist_regular, FontWeight.Normal),
    Font(R.font.geist_medium, FontWeight.Medium),
    Font(R.font.geist_semibold, FontWeight.SemiBold),
    Font(R.font.geist_bold, FontWeight.Bold),
)

/**
 * The code face: Google Sans Code (SIL OFL), a variable font on the weight axis, so each weight of
 * the family is one file at a different axis setting.
 */
@OptIn(ExperimentalTextApi::class)
val CodeFont = FontFamily(
    listOf(400 to FontWeight.Normal, 500 to FontWeight.Medium, 600 to FontWeight.SemiBold, 700 to FontWeight.Bold).map { (axis, weight) ->
        Font(R.font.google_sans_code, weight, variationSettings = FontVariation.Settings(FontVariation.weight(axis)))
    },
)

/** `Theme.sans(size, weight)` and `Theme.mono(size)` from the SwiftUI app. */
fun sans(size: Float, weight: FontWeight = FontWeight.Normal, lineHeight: Float? = null): TextStyle =
    TextStyle(
        fontFamily = GeistSans, fontSize = size.sp, fontWeight = weight,
        lineHeight = (lineHeight ?: (size * 1.3f)).sp,
    )

fun mono(size: Float, weight: FontWeight = FontWeight.Normal, lineHeight: Float? = null): TextStyle =
    TextStyle(
        fontFamily = CodeFont, fontSize = size.sp, fontWeight = weight,
        lineHeight = (lineHeight ?: (size * 1.4f)).sp,
    )

/** The Material 3 type scale, set in Geist, so stock components (sheets, switches, fields) match. */
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
 * Maps the Harness palette onto every Material 3 color role so stock components
 * (bottom sheets, switches, text fields, menus) paint correctly with no
 * per-component overrides.
 */
internal fun HarnessPalette.toColorScheme(): ColorScheme {
    val accentWash = accent.copy(alpha = if (isDark) 0.22f else 0.14f).compositeOver(bg)
    val selectedWash = accent.copy(alpha = if (isDark) 0.16f else 0.10f).compositeOver(bg)
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
        surfaceContainer = surface, surfaceContainerHigh = surfaceRaised, surfaceContainerHighest = highest,
    )
}

@Composable
fun rememberThemeStore(): ThemeStore {
    val context = LocalContext.current
    return remember {
        val json = context.assets.open("themes.json").bufferedReader().use { it.readText() }
        val prefs = context.getSharedPreferences("harness-theme", Context.MODE_PRIVATE)
        ThemeStore(ThemeCatalog.parse(json), prefs)
    }
}

@Composable
fun HarnessTheme(store: ThemeStore, content: @Composable () -> Unit) {
    val variant = store.active(isSystemInDarkTheme())
    val palette = remember(variant) { HarnessPalette(variant) }
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            val controller = WindowCompat.getInsetsController(window, view)
            controller.isAppearanceLightStatusBars = !palette.isDark
            controller.isAppearanceLightNavigationBars = !palette.isDark
        }
    }
    CompositionLocalProvider(LocalThemeStore provides store, LocalPalette provides palette) {
        MaterialTheme(colorScheme = palette.toColorScheme(), typography = harnessTypography(), content = content)
    }
}
