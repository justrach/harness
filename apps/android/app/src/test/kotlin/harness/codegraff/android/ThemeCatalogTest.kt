package harness.codegraff.android

import androidx.compose.ui.graphics.Color
import harness.codegraff.android.theme.ThemeAppearance
import harness.codegraff.android.theme.ThemeCatalog
import harness.codegraff.android.theme.ThemeStore
import harness.codegraff.android.theme.fnv1a
import harness.codegraff.android.theme.projectTintIndex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ThemeCatalogTest {
    private val bundled = File("src/main/assets/themes.json")
    private val source = File("../../ios/Harness/Theme/themes.json")
    private val catalog by lazy { ThemeCatalog.parse(bundled.readText()) }

    @Test
    fun theBundledCatalogMatchesTheOneDesktopAndIosInstall() {
        assertEquals("apps/android/app/src/main/assets/themes.json is stale; copy apps/ios/Harness/Theme/themes.json over it", source.readText(), bundled.readText())
    }

    @Test
    fun everyFamilyParsesAndBothHarnessVariantsExist() {
        assertTrue(catalog.families.size >= 19)
        assertNotNull(catalog.variant(ThemeStore.FALLBACK_LIGHT))
        assertNotNull(catalog.variant(ThemeStore.FALLBACK_DARK))
        assertNotNull(catalog.variant(ThemeStore.DEFAULT_LIGHT))
        assertNotNull(catalog.variant(ThemeStore.DEFAULT_DARK))
        assertEquals(ThemeAppearance.Dark, catalog.variant("codegraff-dark")!!.appearance)
    }

    @Test
    fun hexColorsDecodeInEveryCssForm() {
        assertEquals(Color(1f, 0f, 0f, 1f), ThemeCatalog.parseHex("#f00"))
        assertEquals(Color(1f, 0f, 0f, 0x88 / 255f), ThemeCatalog.parseHex("#f008"))
        assertEquals(Color(0x11 / 255f, 0x22 / 255f, 0x33 / 255f, 1f), ThemeCatalog.parseHex("#112233"))
        assertEquals(Color(0x11 / 255f, 0x22 / 255f, 0x33 / 255f, 0x44 / 255f), ThemeCatalog.parseHex("#11223344"))
    }

    @Test
    fun storeFollowsTheSystemUntilAModeIsChosen() {
        val store = ThemeStore(catalog, null)
        assertEquals("codegraff-dark", store.active(systemDark = true).id)
        assertEquals("codegraff-light", store.active(systemDark = false).id)
        store.setMode(ThemeStore.Mode.Dark)
        assertEquals("codegraff-dark", store.active(systemDark = false).id)
    }

    @Test
    fun aLocalChoiceStopsMatchingTheDesktopAndSwitchesAPinnedMode() {
        val store = ThemeStore(catalog, null)
        store.applyDesktop(harness.codegraff.android.theme.DesktopAppearance("dark", "harnesser-light", "nord"))
        assertTrue(store.isMatchingDesktop)
        assertEquals(ThemeStore.Mode.Dark, store.mode)
        val light = catalog.variant("harnesser-light")!!
        store.select(light)
        assertTrue(!store.followDesktop)
        // Picking a light theme while pinned dark switches the pin so the choice shows.
        assertEquals(ThemeStore.Mode.Light, store.mode)
        assertEquals("harnesser-light", store.active(systemDark = true).id)
        // The dark choice the desktop had is kept, not reset to a stale phone value.
        assertEquals("nord", store.selectedId(ThemeAppearance.Dark))
    }

    @Test
    fun anUnknownThemeIdFallsBackToHarness() {
        val light = ThemeStore(catalog, null)
        light.applyDesktop(harness.codegraff.android.theme.DesktopAppearance("light", "not-a-theme", "also-missing"))
        assertEquals("harnesser-light", light.active(systemDark = false).id)
        val dark = ThemeStore(catalog, null)
        dark.applyDesktop(harness.codegraff.android.theme.DesktopAppearance("dark", "not-a-theme", "also-missing"))
        assertEquals("harnesser-dark", dark.active(systemDark = false).id)
        // An id of the wrong appearance is unknown too.
        val wrong = ThemeStore(catalog, null)
        wrong.applyDesktop(harness.codegraff.android.theme.DesktopAppearance("dark", "codegraff-light", "codegraff-light"))
        assertEquals("harnesser-dark", wrong.active(systemDark = true).id)
    }

    @Test
    fun projectTintsAreStableAcrossLaunches() {
        // FNV-1a 64-bit test vectors: a project's color must never depend on the run.
        assertEquals(0xcbf29ce484222325uL, fnv1a(""))
        assertEquals(0xaf63dc4c8601ec8cuL, fnv1a("a"))
        val indices = listOf("space-harness", "space-edge", "a", "b", "c").map(::projectTintIndex)
        assertTrue(indices.all { it in 0..7 })
        assertEquals(projectTintIndex("space-harness"), projectTintIndex("space-harness"))
    }
}
