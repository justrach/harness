package harness.codegraff.android

import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.Attention
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.TranscriptRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)

    @After fun tearDown() = Dispatchers.resetMain()

    @Test
    fun activeListSortsByCalledAndSplitsArchived() {
        val model = AppModel(clock = { 1_000_000L })
        assertEquals(listOf("chat-veil", "chat-picker", "chat-tabs", "chat-deploy"), model.state.value.active.map { it.id })
        assertEquals(listOf("chat-oklch", "chat-presence"), model.state.value.archived.map { it.id })
    }

    @Test
    fun openingASessionMarksItSeenAndClearsNeedsYou() {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now })
        val before = model.state.value
        assertTrue(before.chat("chat-tabs")!!.unseen)
        assertEquals(Attention.NeedsYou, before.attention(before.chat("chat-tabs")!!))
        now += 5
        model.markSeen("chat-tabs")
        val after = model.state.value
        assertFalse(after.chat("chat-tabs")!!.unseen)
        assertEquals(Attention.None, after.attention(after.chat("chat-tabs")!!))
    }

    @Test
    fun homeCountsMatchTheSwitcher() {
        val state = AppModel(clock = { 1_000_000L }).state.value
        // Picker is waiting on you and Tabs is unread; Veil is running.
        assertEquals(2, state.needsYouCount)
        assertEquals(1, state.runningCount)
    }

    @Test
    fun sendAppendsUserRowAndStreamsReplyToCompletion() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        model.send("chat-tabs", "  ship it  ")
        val started = model.state.value.transcript("chat-tabs").takeLast(2)
        assertEquals("ship it", (started[0] as TranscriptRow.User).text)
        assertTrue((started[1] as TranscriptRow.Assistant).live)
        assertEquals(SessionStatus.Working, model.state.value.sessions["chat-tabs"]?.status)

        advanceUntilIdle()

        val reply = model.state.value.transcript("chat-tabs").last() as TranscriptRow.Assistant
        assertFalse(reply.live)
        assertEquals(DemoDataset.STREAM_REPLY, reply.text)
        assertNull(model.state.value.sessions["chat-tabs"])
        assertEquals("ship it", model.state.value.chats.first { it.id == "chat-tabs" }.lastMessagePreview)
    }

    @Test
    fun blankSendIsIgnored() {
        val model = AppModel(clock = { 1L })
        val before = model.state.value.transcript("chat-tabs").size
        model.send("chat-tabs", "   ")
        assertEquals(before, model.state.value.transcript("chat-tabs").size)
    }
}
