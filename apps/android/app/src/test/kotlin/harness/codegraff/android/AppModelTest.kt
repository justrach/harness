package harness.codegraff.android

import harness.codegraff.android.demo.DemoDataset
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
    fun openingMarksSeenAndBackCloses() {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now })
        assertTrue(model.state.value.chats.first { it.id == "chat-tabs" }.unseen)
        now += 5
        model.open("chat-tabs")
        assertEquals("chat-tabs", model.state.value.openChat?.id)
        assertFalse(model.state.value.chats.first { it.id == "chat-tabs" }.unseen)
        model.back()
        assertNull(model.state.value.openChat)
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
