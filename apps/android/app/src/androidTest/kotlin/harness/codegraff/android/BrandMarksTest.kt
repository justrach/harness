package harness.codegraff.android

import androidx.compose.ui.graphics.vector.PathParser
import androidx.test.ext.junit.runners.AndroidJUnit4
import harness.codegraff.android.theme.BrandMark
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Every provider logo is the desktop's exact SVG path data, so each one must parse to real geometry. */
@RunWith(AndroidJUnit4::class)
class BrandMarksTest {
    @Test
    fun everyMarkParsesToANonEmptyPath() {
        for (mark in BrandMark.entries) {
            val path = PathParser().parsePathString(mark.pathData).toPath()
            assertFalse("${mark.name} parsed empty", path.isEmpty)
            val bounds = path.getBounds()
            assertTrue("${mark.name} has no area", bounds.width > 0f && bounds.height > 0f)
        }
    }

    @Test
    fun harnessIdsMapToTheRightMark() {
        assertTrue(BrandMark.forHarness("codex") == BrandMark.OpenAi)
        assertTrue(BrandMark.forHarness("claude-code") == BrandMark.Claude)
        assertTrue(BrandMark.forHarness("mock") == BrandMark.Claude)
        assertTrue(BrandMark.forHarness("hermes") == BrandMark.Hermes)
    }
}
