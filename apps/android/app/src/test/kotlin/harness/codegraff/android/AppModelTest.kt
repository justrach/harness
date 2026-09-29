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
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)

    @After fun tearDown() = Dispatchers.resetMain()

    private fun model(now: Long = 1_000_000L) = AppModel(clock = { now }, tickMs = 1)

    private val AppModel.ws get() = state.workspace

    @Test
    fun homeListsActiveSessionsByCalledAtAndKeepsArchivedApart() {
        val ws = model().ws
        assertEquals(listOf("chat-veil", "chat-picker", "chat-tabs", "chat-deploy"), ws.overviewChats.map { it.id })
        assertEquals(listOf("chat-oklch", "chat-presence"), ws.archivedMatches(null, "").map { it.id })
    }

    @Test
    fun indicatorsMatchTheDemoFixtures() {
        val ws = model().ws
        assertEquals(ChatIndicator.Working, ws.indicator(ws.chat("chat-veil")!!))
        assertEquals(ChatIndicator.AwaitingInput, ws.indicator(ws.chat("chat-picker")!!))
        assertEquals(ChatIndicator.Completed, ws.indicator(ws.chat("chat-tabs")!!))
        assertEquals(ChatIndicator.Idle, ws.indicator(ws.chat("chat-deploy")!!))
    }

    @Test
    fun openingASessionMarksItSeenOnceAndOnlyWhenUnseen() {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now })
        assertEquals(ChatIndicator.Completed, model.ws.indicator(model.ws.chat("chat-tabs")!!))
        now += 5
        model.markSeen("chat-tabs")
        assertEquals(ChatIndicator.Idle, model.ws.indicator(model.ws.chat("chat-tabs")!!))
        // Marking an already-seen session must not publish a new workspace (leaving a session does this).
        val before = model.ws
        model.markSeen("chat-tabs")
        assertSame(before, model.ws)
    }

    @Test
    fun archiveAndUnarchiveMoveSessionsBetweenShelves() {
        val model = model()
        model.archive("chat-deploy")
        assertFalse("chat-deploy" in model.ws.overviewChats.map { it.id })
        assertTrue("chat-deploy" in model.ws.archivedMatches(null, "").map { it.id })
        model.unarchive("chat-deploy")
        assertTrue("chat-deploy" in model.ws.overviewChats.map { it.id })
    }

    @Test
    fun pinnedSessionsLeadTheList() {
        val model = model()
        model.setPinned("chat-deploy", true)
        assertEquals("chat-deploy", model.ws.overviewChats.first().id)
        assertTrue(model.ws.isPinned("chat-deploy"))
        model.setPinned("chat-deploy", false)
        assertEquals("chat-veil", model.ws.overviewChats.first().id)
    }

    @Test
    fun archivedSearchScopesBySpaceAndQuery() {
        val ws = model().ws
        assertEquals(listOf("chat-presence"), ws.archivedMatches("space-edge", "").map { it.id })
        assertEquals(listOf("chat-oklch"), ws.archivedMatches(null, "oklch").map { it.id })
        assertTrue(ws.archivedMatches(null, "no such thing").isEmpty())
    }

    @Test
    fun sendAppendsTheTurnAndStreamsTheReplyToCompletion() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        model.send("chat-tabs", "  ship it  ")
        val started = model.entries("chat-tabs").takeLast(2)
        assertEquals(MessageRole.User, started[0].role)
        assertEquals("ship it", (started[0].parts.single() as MessagePart.Text).text)
        assertEquals(MessageStatus.Streaming, started[1].status)
        assertEquals(SessionStatus.Working, model.ws.sessions["chat-tabs"]?.status)

        advanceUntilIdle()

        val reply = model.entries("chat-tabs").last()
        assertEquals(MessageStatus.Complete, reply.status)
        assertEquals(DemoDataset.STREAM_REPLY, (reply.parts.single() as MessagePart.Text).text)
        assertEquals(SessionStatus.Idle, model.ws.sessions["chat-tabs"]?.status)
        assertNotNull(model.ws.chat("chat-tabs")!!.lastPromptAt)
    }

    @Test
    fun aStreamedTokenNeverRepublishesTheWorkspace() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 5)
        model.send("chat-tabs", "go")
        val workspaceAtStart = model.ws
        val entriesAtStart = model.entries("chat-tabs")
        advanceTimeBy(30)
        // Tokens replaced only this chat's transcript: Home and the switcher have nothing to recompose.
        assertSame(workspaceAtStart, model.ws)
        assertTrue(model.entries("chat-tabs") !== entriesAtStart)
        // Other chats' lists keep their identity too.
        val deploy = model.entries("chat-deploy")
        advanceTimeBy(30)
        assertSame(deploy, model.entries("chat-deploy"))
        advanceUntilIdle()
    }

    @Test
    fun blankSendIsIgnored() {
        val model = model()
        val before = model.entries("chat-tabs").size
        model.send("chat-tabs", "   ")
        assertEquals(before, model.entries("chat-tabs").size)
    }

    @Test
    fun interruptSettlesTheLiveEntryAsAborted() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        model.send("chat-tabs", "go")
        model.interrupt("chat-tabs")
        advanceUntilIdle()
        assertEquals(MessageStatus.Aborted, model.entries("chat-tabs").last().status)
        assertEquals(SessionStatus.Idle, model.ws.sessions["chat-tabs"]?.status)
    }

    @Test
    fun answeringAQuestionResolvesItAndStopsWaiting() {
        val model = model()
        model.respondInput("chat-picker", "req-1", listOf(UserInputAnswer("q1", listOf("Local device"))))
        val input = model.entries("chat-picker").flatMap { it.parts }.filterIsInstance<MessagePart.Input>().single()
        assertTrue(input.resolved)
        assertNull(model.ws.sessions["chat-picker"])
    }

    @Test
    fun newChatsCarryTheirConfigAndTitleFromTheFirstPrompt() = runTest(dispatcher) {
        var now = 10_000_000_000L
        val model = AppModel(clock = { now++ }, tickMs = 1)
        val space = model.ws.spaces.first()
        val id = model.createChat(space, ChatConfig("codex", "gpt-5.4", "high"), "main", null)
        assertEquals("codex", model.ws.chat(id)!!.config!!.harness)
        model.send(id, "Sketch the plan for porting the diff pane.")
        assertEquals("Sketch the plan for porting the diff pane.", model.ws.chat(id)!!.title)
        advanceUntilIdle()
    }

    @Test
    fun projectlessChatsHaveNoSpaceAndRunInHome() {
        val model = model()
        val id = model.createProjectlessChat("dev-mac", ChatConfig("claude-code"))
        val chat = model.ws.chat(id)!!
        assertNull(chat.spaceId)
        assertEquals("~", chat.cwd)
        assertNotNull(model.ws.overviewChats.firstOrNull { it.id == id })
    }

    @Test
    fun chatConfigEditsMergeIntoTheExistingConfig() {
        val model = model()
        model.setChatConfig("chat-veil", "claude-opus-5", "max", mapOf("fastMode" to "on"))
        val config = model.ws.chat("chat-veil")!!.config!!
        assertEquals("claude-code", config.harness)
        assertEquals("claude-opus-5", config.model)
        assertEquals("max", config.reasoning)
        assertEquals(mapOf("fastMode" to "on"), config.modelOptions)
    }

    @Test
    fun theSlowClockMovesNowForward() = runTest(dispatcher) {
        var now = 1_000L
        val model = AppModel(clock = { now })
        val job = launch { model.runClock(everyMs = 100) }
        now = 5_000L
        advanceTimeBy(150)
        assertEquals(5_000L, model.ws.now)
        job.cancel()
    }
}
