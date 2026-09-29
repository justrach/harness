package harness.codegraff.android

import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.UserInputAnswer
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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)

    @After fun tearDown() = Dispatchers.resetMain()

    private fun model(now: Long = 1_000_000L) = AppModel(clock = { now }, tickMs = 1)

    @Test
    fun homeListsActiveSessionsByCalledAtAndKeepsArchivedApart() {
        val state = model().state.value
        assertEquals(listOf("chat-veil", "chat-picker", "chat-tabs", "chat-deploy"), state.overviewChats.map { it.id })
        assertEquals(listOf("chat-oklch", "chat-presence"), state.archivedMatches(null, "").map { it.id })
    }

    @Test
    fun indicatorsMatchTheDemoFixtures() {
        val state = model().state.value
        assertEquals(ChatIndicator.Working, state.indicator(state.chat("chat-veil")!!))
        assertEquals(ChatIndicator.AwaitingInput, state.indicator(state.chat("chat-picker")!!))
        assertEquals(ChatIndicator.Completed, state.indicator(state.chat("chat-tabs")!!))
        assertEquals(ChatIndicator.Idle, state.indicator(state.chat("chat-deploy")!!))
    }

    @Test
    fun openingASessionMarksItSeen() {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now })
        assertEquals(ChatIndicator.Completed, model.state.value.indicator(model.state.value.chat("chat-tabs")!!))
        now += 5
        model.markSeen("chat-tabs")
        assertEquals(ChatIndicator.Idle, model.state.value.indicator(model.state.value.chat("chat-tabs")!!))
    }

    @Test
    fun archiveAndUnarchiveMoveSessionsBetweenShelves() {
        val model = model()
        model.archive("chat-deploy")
        assertFalse("chat-deploy" in model.state.value.overviewChats.map { it.id })
        assertTrue("chat-deploy" in model.state.value.archivedMatches(null, "").map { it.id })
        model.unarchive("chat-deploy")
        assertTrue("chat-deploy" in model.state.value.overviewChats.map { it.id })
    }

    @Test
    fun pinnedSessionsLeadTheList() {
        val model = model()
        model.setPinned("chat-deploy", true)
        assertEquals("chat-deploy", model.state.value.overviewChats.first().id)
        assertTrue(model.state.value.isPinned("chat-deploy"))
        model.setPinned("chat-deploy", false)
        assertEquals("chat-veil", model.state.value.overviewChats.first().id)
    }

    @Test
    fun archivedSearchScopesBySpaceAndQuery() {
        val state = model().state.value
        assertEquals(listOf("chat-presence"), state.archivedMatches("space-edge", "").map { it.id })
        assertEquals(listOf("chat-oklch"), state.archivedMatches(null, "oklch").map { it.id })
        assertTrue(state.archivedMatches(null, "no such thing").isEmpty())
    }

    @Test
    fun sendAppendsTheTurnAndStreamsTheReplyToCompletion() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        model.send("chat-tabs", "  ship it  ")
        val started = model.state.value.entries("chat-tabs").takeLast(2)
        assertEquals(MessageRole.User, started[0].role)
        assertEquals("ship it", (started[0].parts.single() as MessagePart.Text).text)
        assertEquals(MessageStatus.Streaming, started[1].status)
        assertEquals(SessionStatus.Working, model.state.value.sessions["chat-tabs"]?.status)

        advanceUntilIdle()

        val reply = model.state.value.entries("chat-tabs").last()
        assertEquals(MessageStatus.Complete, reply.status)
        assertEquals(DemoDataset.STREAM_REPLY, (reply.parts.single() as MessagePart.Text).text)
        assertEquals(SessionStatus.Idle, model.state.value.sessions["chat-tabs"]?.status)
        assertNotNull(model.state.value.chat("chat-tabs")!!.lastPromptAt)
    }

    @Test
    fun blankSendIsIgnored() {
        val model = model()
        val before = model.state.value.entries("chat-tabs").size
        model.send("chat-tabs", "   ")
        assertEquals(before, model.state.value.entries("chat-tabs").size)
    }

    @Test
    fun interruptSettlesTheLiveEntryAsAborted() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        model.send("chat-tabs", "go")
        model.interrupt("chat-tabs")
        advanceUntilIdle()
        assertEquals(MessageStatus.Aborted, model.state.value.entries("chat-tabs").last().status)
        assertEquals(SessionStatus.Idle, model.state.value.sessions["chat-tabs"]?.status)
    }

    @Test
    fun answeringAQuestionResolvesItAndStopsWaiting() {
        val model = model()
        model.respondInput("chat-picker", "req-1", listOf(UserInputAnswer("q1", listOf("Local device"))))
        val input = model.state.value.entries("chat-picker").flatMap { it.parts }.filterIsInstance<MessagePart.Input>().single()
        assertTrue(input.resolved)
        assertNull(model.state.value.sessions["chat-picker"])
    }

    @Test
    fun newChatsCarryTheirConfigAndTitleFromTheFirstPrompt() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        val space = model.state.value.spaces.first()
        val id = model.createChat(space, ChatConfig("codex", "gpt-5.4", "high"), "main", null)
        assertEquals("codex", model.state.value.chat(id)!!.config!!.harness)
        model.send(id, "Sketch the plan for porting the diff pane.")
        assertEquals("Sketch the plan for porting the diff pane.", model.state.value.chat(id)!!.title)
        advanceUntilIdle()
    }

    @Test
    fun projectlessChatsHaveNoSpaceAndRunInHome() {
        val model = model()
        val id = model.createProjectlessChat("dev-mac", ChatConfig("claude-code"))
        val chat = model.state.value.chat(id)!!
        assertNull(chat.spaceId)
        assertEquals("~", chat.cwd)
        assertNotNull(model.state.value.overviewChats.firstOrNull { it.id == id })
    }

    @Test
    fun chatConfigEditsMergeIntoTheExistingConfig() {
        val model = model()
        model.setChatConfig("chat-veil", "claude-opus-5", "max", mapOf("fastMode" to "on"))
        val config = model.state.value.chat("chat-veil")!!.config!!
        assertEquals("claude-code", config.harness)
        assertEquals("claude-opus-5", config.model)
        assertEquals("max", config.reasoning)
        assertEquals(mapOf("fastMode" to "on"), config.modelOptions)
    }
}
