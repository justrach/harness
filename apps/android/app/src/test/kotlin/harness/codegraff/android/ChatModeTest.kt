package harness.codegraff.android

import harness.codegraff.android.model.ChatMode
import harness.codegraff.android.model.DeviceCatalog
import harness.codegraff.android.model.HarnessInfo
import harness.codegraff.android.model.ModelInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Chat mode offers graff's three auto tiers only, notes Auto (smart)'s API costs, and says why when none is listed (ChatModeTests.swift). */
class ChatModeTest {
    private fun model(id: String, label: String) = ModelInfo(id, label, null, listOf("low", "high"))

    @Test
    fun onlyTheAutoTiersAreOfferedInOrderUnderTheirNames() {
        val offered = ChatMode.models(
            listOf(
                model("codegraff/auto-smart", "auto-smart"),
                model("codegraff/claude-opus-5-5", "Claude Opus 5.5"),
                model("codegraff/auto-high", "Auto (high)"),
                model("chatgpt-new/gpt-6.1-sol", "GPT-6.1 Sol"),
                model("codegraff/auto-low", "Auto (low)"),
            ),
        )
        assertEquals(listOf("codegraff/auto-low", "codegraff/auto-high", "codegraff/auto-smart"), offered.map { it.id })
        assertEquals(listOf("Auto (low)", "Auto (high)", "Auto (smart)"), offered.map { it.label })
        assertEquals("May incur API costs.", offered[2].description)
        assertTrue(offered.all { it.reasoningLevels.isEmpty() })
    }

    @Test
    fun anOlderGatewayOffersAutoMediumAsAutoLowAndNoTierIsInvented() {
        val offered = ChatMode.models(listOf(model("codegraff/auto-medium", "Auto (medium)"), model("codegraff/auto-high", "Auto (high)")))
        assertEquals(listOf("codegraff/auto-medium", "codegraff/auto-high"), offered.map { it.id })
        assertEquals("Auto (low)", offered.first().label)
        assertTrue(ChatMode.models(emptyList()).isEmpty())
    }

    @Test
    fun aChatWaitsForAReplyThenSaysWhyItCantStart() {
        val pending = ChatMode.selection("", DeviceCatalog())
        assertEquals("", pending.model.id)
        assertFalse(pending.canSend)
        assertFalse("no reply yet is not a verdict", pending.unavailable)

        val noTiers = DeviceCatalog(listOf(model("codegraff/claude-opus-5-5", "Claude Opus 5.5")), isLive = true)
        assertEquals(ChatMode.Availability.Unavailable, ChatMode.availability(noTiers))
        assertTrue(ChatMode.selection("", noTiers).unavailable)

        val noGraff = DeviceCatalog(listOf(HarnessInfo("codex", "Codex")), isLive = true)
        assertEquals(ChatMode.Availability.Unavailable, ChatMode.availability(DeviceCatalog(), noGraff))

        val cached = DeviceCatalog(listOf(model("codegraff/auto-high", "Auto (high)")))
        assertEquals(ChatMode.Availability.Available, ChatMode.availability(cached))
        assertTrue(ChatMode.selection("codegraff/auto-smart", cached).canSend)
        assertEquals("codegraff/auto-high", ChatMode.selection("codegraff/auto-smart", cached).model.id)
        assertEquals("Chat needs the hosted Auto models, which aren't available right now.", ChatMode.UNAVAILABLE_NOTE)
    }

    @Test
    fun theCostNoteBelongsToAutoSmartOnly() {
        assertEquals("Auto (smart) may incur API costs.", ChatMode.note("codegraff/auto-smart"))
        assertNull(ChatMode.note("codegraff/auto-high"))
        assertNull(ChatMode.note("codegraff/auto-medium"))
        assertNull(ChatMode.note(null))
    }
}
