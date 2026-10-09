package harness.codegraff.android

import harness.codegraff.android.core.coreVersion
import harness.codegraff.android.core.encodeHlc
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The JVM loads the host build of the native core (crates/mobile) through the generated UniFFI bindings. */
class NativeCoreTest {
    @Test
    fun theBindingsReachTheNativeCore() {
        assertTrue(coreVersion().matches(Regex("""\d+\.\d+\.\d+.*""")))
    }

    @Test
    fun registryClocksAreTheSharedFormat() {
        // RegistryCore.swift encodeHlc gives the same string for these inputs.
        assertEquals("0000000000005-000007-phone", encodeHlc(5, 7u, "phone"))
        assertTrue(encodeHlc(10, 0u, "a") > encodeHlc(9, 999_999u, "z"))
    }
}
