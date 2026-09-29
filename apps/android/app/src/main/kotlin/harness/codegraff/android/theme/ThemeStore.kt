package harness.codegraff.android.theme

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** The desktop's appearance choice as published to the synced registry. */
data class DesktopAppearance(val mode: String, val light: String, val dark: String)

/**
 * The active theme: a light and a dark variant from the desktop catalog plus an
 * appearance mode (ThemeStore.swift). By default the phone matches the desktop,
 * which publishes its choice; a local choice stops matching and is persisted.
 * State is Compose state, so anything painting a token recomposes on change.
 */
class ThemeStore(
    val catalog: ThemeCatalog,
    private val prefs: SharedPreferences?,
) {
    enum class Mode(val label: String) { System("System"), Light("Light"), Dark("Dark") }

    private var ownMode by mutableStateOf(
        prefs?.getString(KEY_MODE, null)?.let { s -> Mode.entries.firstOrNull { it.name.lowercase() == s } } ?: Mode.System,
    )
    private var ownLight by mutableStateOf(prefs?.getString(KEY_LIGHT, null) ?: DEFAULT_LIGHT)
    private var ownDark by mutableStateOf(prefs?.getString(KEY_DARK, null) ?: DEFAULT_DARK)

    /** "Match desktop": on by default; the first local choice turns it off. */
    private var follow by mutableStateOf(prefs?.getBoolean(KEY_FOLLOW, true) ?: true)
    val followDesktop: Boolean get() = follow

    /** The desktop's latest published choice (null until one has synced). */
    var desktop by mutableStateOf<DesktopAppearance?>(null)
        private set

    private val desktopMode: Mode?
        get() = desktop?.let { d -> Mode.entries.firstOrNull { it.name.lowercase() == d.mode } }

    val isMatchingDesktop: Boolean get() = followDesktop && desktopMode != null

    /** The mode in effect: the desktop's while matching, else the phone's. */
    val mode: Mode get() = if (isMatchingDesktop) desktopMode!! else ownMode

    fun selectedId(appearance: ThemeAppearance): String {
        val d = desktop
        if (isMatchingDesktop && d != null) return if (appearance.isDark) d.dark else d.light
        return if (appearance.isDark) ownDark else ownLight
    }

    /** The variant in effect for a device that is currently [systemDark]. */
    fun active(systemDark: Boolean): ThemeVariant {
        val appearance = when (mode) {
            Mode.System -> if (systemDark) ThemeAppearance.Dark else ThemeAppearance.Light
            Mode.Light -> ThemeAppearance.Light
            Mode.Dark -> ThemeAppearance.Dark
        }
        return variant(selectedId(appearance), appearance)
    }

    fun applyDesktop(appearance: DesktopAppearance?) {
        desktop = appearance
    }

    fun setFollowDesktop(follow: Boolean) {
        if (follow == followDesktop) return
        if (!follow) adoptEffectiveChoice()
        this.follow = follow
        prefs?.edit()?.putBoolean(KEY_FOLLOW, follow)?.apply()
    }

    /** Choose a mode on the phone (stops matching the desktop). */
    fun setMode(mode: Mode) {
        detachFromDesktop()
        if (mode == ownMode) return
        ownMode = mode
        persist(KEY_MODE, mode.name.lowercase())
    }

    /**
     * Choose [variant] for its appearance (stops matching the desktop). Picking a light
     * theme while the app is pinned dark (or vice versa) switches the pin so the choice shows.
     */
    fun select(variant: ThemeVariant) {
        detachFromDesktop()
        if (variant.appearance.isDark) {
            ownDark = variant.id
            persist(KEY_DARK, variant.id)
        } else {
            ownLight = variant.id
            persist(KEY_LIGHT, variant.id)
        }
        if (ownMode != Mode.System && (ownMode == Mode.Dark) != variant.appearance.isDark) {
            ownMode = if (variant.appearance.isDark) Mode.Dark else Mode.Light
            persist(KEY_MODE, ownMode.name.lowercase())
        }
    }

    /** A local choice starts from what's on screen, so changing one thing never makes the others jump. */
    private fun detachFromDesktop() {
        if (isMatchingDesktop) setFollowDesktop(false)
    }

    private fun adoptEffectiveChoice() {
        if (!isMatchingDesktop) return
        val (m, light, dark) = Triple(mode, selectedId(ThemeAppearance.Light), selectedId(ThemeAppearance.Dark))
        ownMode = m
        ownLight = light
        ownDark = dark
        persist(KEY_MODE, m.name.lowercase())
        persist(KEY_LIGHT, light)
        persist(KEY_DARK, dark)
    }

    private fun persist(key: String, value: String) {
        prefs?.edit()?.putString(key, value)?.apply()
    }

    /** The desktop's fallback rule: an unknown id, or one of the wrong appearance, resolves to Harness. */
    private fun variant(id: String, appearance: ThemeAppearance): ThemeVariant {
        catalog.variant(id)?.takeIf { it.appearance == appearance }?.let { return it }
        val fallback = if (appearance.isDark) FALLBACK_DARK else FALLBACK_LIGHT
        return checkNotNull(catalog.variant(fallback)) { "the catalog always contains both Harness variants" }
    }

    companion object {
        /** New installs match a new desktop install: Codegraff, following the device. */
        const val DEFAULT_LIGHT = "codegraff-light"
        const val DEFAULT_DARK = "codegraff-dark"
        const val FALLBACK_LIGHT = "harnesser-light"
        const val FALLBACK_DARK = "harnesser-dark"
        private const val KEY_MODE = "theme.mode"
        private const val KEY_LIGHT = "theme.light"
        private const val KEY_DARK = "theme.dark"
        private const val KEY_FOLLOW = "theme.followDesktop"
    }
}
