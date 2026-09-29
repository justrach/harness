package harness.codegraff.android.theme

import androidx.compose.ui.graphics.Color
import org.json.JSONObject

// The desktop's built-in theme registry, read from `themes.json` (a copy of
// apps/ios/Harness/Theme/themes.json; a unit test fails when they drift). Every
// family, variant id and color is the one desktop and iOS install. Only the
// roles the phone paints are decoded, like ThemeCatalog.swift.

enum class ThemeAppearance { Light, Dark;
    val isDark: Boolean get() = this == Dark
}

data class VariantColors(
    val background: Color, val shell: Color, val raised: Color, val card: Color,
    val dialog: Color, val hover: Color, val active: Color,
    val border: Color, val borderStrong: Color,
    val text: Color, val textMuted: Color, val textFaint: Color,
    val danger: Color, val dangerMuted: Color, val warning: Color, val success: Color,
    val input: Color,
)

data class VariantAccent(
    val primary: Color, val strong: Color, val wash: Color, val on: Color,
    val selection: Color, val activity: Color,
)

data class ThemeVariant(
    val id: String,
    val familyId: String,
    val name: String,
    val appearance: ThemeAppearance,
    val colors: VariantColors,
    val accent: VariantAccent,
    val syntax: Map<String, Color>,
)

data class ThemeFamily(val id: String, val name: String, val variants: List<ThemeVariant>)

class ThemeCatalog(val families: List<ThemeFamily>) {
    val variants: List<ThemeVariant> = families.flatMap { it.variants }

    fun variant(id: String): ThemeVariant? = variants.firstOrNull { it.id == id }

    companion object {
        fun parse(json: String): ThemeCatalog {
            val families = JSONObject(json).getJSONArray("families")
            return ThemeCatalog(
                (0 until families.length()).map { i ->
                    val family = families.getJSONObject(i)
                    val variants = family.getJSONArray("variants")
                    ThemeFamily(
                        id = family.getString("id"),
                        name = family.getString("name"),
                        variants = (0 until variants.length()).map { parseVariant(variants.getJSONObject(it)) },
                    )
                },
            )
        }

        private fun parseVariant(v: JSONObject): ThemeVariant {
            val c = v.getJSONObject("colors")
            val a = v.getJSONObject("accent")
            fun color(o: JSONObject, key: String) = parseHex(o.getString(key))
            val syntaxJson = v.optJSONObject("syntax")
            val syntax = buildMap {
                syntaxJson?.keys()?.forEach { put(it, parseHex(syntaxJson.getString(it))) }
            }
            return ThemeVariant(
                id = v.getString("id"),
                familyId = v.getString("familyId"),
                name = v.getString("name"),
                appearance = if (v.getString("appearance") == "dark") ThemeAppearance.Dark else ThemeAppearance.Light,
                colors = VariantColors(
                    background = color(c, "background"), shell = color(c, "shell"), raised = color(c, "raised"),
                    card = color(c, "card"), dialog = color(c, "dialog"), hover = color(c, "hover"),
                    active = color(c, "active"), border = color(c, "border"), borderStrong = color(c, "borderStrong"),
                    text = color(c, "text"), textMuted = color(c, "textMuted"), textFaint = color(c, "textFaint"),
                    danger = color(c, "danger"), dangerMuted = color(c, "dangerMuted"),
                    warning = color(c, "warning"), success = color(c, "success"), input = color(c, "input"),
                ),
                accent = VariantAccent(
                    primary = color(a, "primary"), strong = color(a, "strong"), wash = color(a, "wash"),
                    on = color(a, "on"), selection = color(a, "selection"), activity = color(a, "activity"),
                ),
                syntax = syntax,
            )
        }

        /** A CSS hex color (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`), the encoding the Rust `Color` serializes to. */
        fun parseHex(css: String): Color {
            require(css.startsWith("#")) { "expected a CSS hex color, got $css" }
            var digits = css.drop(1)
            if (digits.length == 3 || digits.length == 4) digits = digits.map { "$it$it" }.joinToString("")
            require(digits.length == 6 || digits.length == 8) { "expected a CSS hex color, got $css" }
            val value = digits.toLong(16)
            val rgba = if (digits.length == 8) value else (value shl 8) or 0xff
            return Color(
                red = ((rgba shr 24) and 0xff) / 255f,
                green = ((rgba shr 16) and 0xff) / 255f,
                blue = ((rgba shr 8) and 0xff) / 255f,
                alpha = (rgba and 0xff) / 255f,
            )
        }
    }
}
