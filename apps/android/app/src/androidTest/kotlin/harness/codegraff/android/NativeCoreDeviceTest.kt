package harness.codegraff.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import harness.codegraff.android.core.coreVersion
import harness.codegraff.android.core.encodeHlc
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The APK carries the native core for the device's ABI, and JNA loads it. */
@RunWith(AndroidJUnit4::class)
class NativeCoreDeviceTest {
    @Test
    fun theNativeCoreLoadsOnTheDevice() {
        assertTrue(coreVersion().isNotEmpty())
        assertEquals("0000000000005-000007-phone", encodeHlc(5, 7u, "phone"))
    }
}
