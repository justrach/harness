// Generated from apps/ios/Harness/Theme/themes.json (family "harnesser"), the same
// registry the desktop and iOS apps paint from. Regenerate, do not hand-edit.
package harness.codegraff.android.theme

import androidx.compose.ui.graphics.Color

data class HarnessPalette(
    val isDark: Boolean,
    val bg: Color, val surface: Color, val surfaceRaised: Color, val surfaceDialog: Color,
    val hover: Color, val active: Color, val border: Color, val borderStrong: Color,
    val text: Color, val textMuted: Color, val textFaint: Color,
    val accent: Color, val accentStrong: Color, val accentOn: Color,
    val danger: Color, val warning: Color, val success: Color,
)

val HarnessLight = HarnessPalette(
    isDark = false,
    bg = Color(0xFFFFFFFF),
    surface = Color(0xFFF3F3F5),
    surfaceRaised = Color(0xFFEDEDF0),
    surfaceDialog = Color(0xFFFEFEFE),
    hover = Color(0x0F000000),
    active = Color(0x1A5B43E8),
    border = Color(0x1F000000),
    borderStrong = Color(0x38000000),
    text = Color(0xFF303035),
    textMuted = Color(0xFF62626A),
    textFaint = Color(0xFF797981),
    accent = Color(0xFF5B43E8),
    accentStrong = Color(0xFF5B43E8),
    accentOn = Color(0xFFFFFFFF),
    danger = Color(0xFFDC2626),
    warning = Color(0xFFA16207),
    success = Color(0xFF15803D),
)

val HarnessDark = HarnessPalette(
    isDark = true,
    bg = Color(0xFF060606),
    surface = Color(0xFF0D0D0D),
    surfaceRaised = Color(0xFF343438),
    surfaceDialog = Color(0xFF151516),
    hover = Color(0x1CFFFFFF),
    active = Color(0x2E8B7CF6),
    border = Color(0x1AFFFFFF),
    borderStrong = Color(0x2EFFFFFF),
    text = Color(0xFFE8E8EA),
    textMuted = Color(0xFFA9A9AE),
    textFaint = Color(0xFF85858A),
    accent = Color(0xFF8B7CF6),
    accentStrong = Color(0xFF8B7CF6),
    accentOn = Color(0xFF000000),
    danger = Color(0xFFF87171),
    warning = Color(0xFFFACC15),
    success = Color(0xFF34D399),
)
