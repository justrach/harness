package harness.codegraff.android

import harness.codegraff.android.ui.heightAboveHinge
import org.junit.Assert.assertEquals
import org.junit.Test

class PostureTest {
    @Test
    fun contentEndsAtTheFold() {
        assertEquals(700f, heightAboveHinge(hingeTop = 900f, contentTop = 200f), 0f)
    }

    @Test
    fun neverNegativeWhenTheFoldIsAboveTheContent() {
        assertEquals(0f, heightAboveHinge(hingeTop = 100f, contentTop = 200f), 0f)
    }
}
