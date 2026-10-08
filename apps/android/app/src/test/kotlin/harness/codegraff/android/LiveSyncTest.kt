package harness.codegraff.android

import harness.codegraff.android.core.ChatConfigRecord
import harness.codegraff.android.core.ChatRecord
import harness.codegraff.android.core.DeviceRecord
import harness.codegraff.android.core.MessageEntryRecord
import harness.codegraff.android.core.MessagePartRecord
import harness.codegraff.android.core.MessageRoleRecord
import harness.codegraff.android.core.MessageStatusRecord
import harness.codegraff.android.core.MobileCoreInterface
import harness.codegraff.android.core.NewChatConfig
import harness.codegraff.android.core.QueueDeliveryGateRecord
import harness.codegraff.android.core.QueuedMessageRecord
import harness.codegraff.android.core.SessionRowRecord
import harness.codegraff.android.core.SessionSnapshot
import harness.codegraff.android.core.SessionStatusRecord
import harness.codegraff.android.core.SpaceRecord
import harness.codegraff.android.core.TaskItemRecord
import harness.codegraff.android.core.ToolFieldRecord
import harness.codegraff.android.core.WorkspaceSnapshot
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.QueueDeliveryGate
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.sync.LiveFeed
import harness.codegraff.android.sync.LiveSync
import harness.codegraff.android.sync.toModel
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
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Records the calls the model makes into the native core, and answers them like it would. */
private class FakeCore : MobileCoreInterface {
    val calls = mutableListOf<String>()
    var started = false
    override fun start() { started = true }
    override fun workspace(): WorkspaceSnapshot = error("not used")
    override fun openSession(chatId: String) = SessionSnapshot(chatId, emptyList(), emptyList(), false, null, false).also { calls += "open $chatId" }
    override fun closeSession(chatId: String) { calls += "close $chatId" }
    override fun setArchived(chatId: String, archived: Boolean) = true.also { calls += "archive $chatId $archived" }
    override fun rename(chatId: String, title: String) = true.also { calls += "rename $chatId $title" }
    override fun setPinned(chatId: String, pinned: Boolean) = true.also { calls += "pin $chatId $pinned" }
    override fun markSeen(chatId: String) = true.also { calls += "seen $chatId" }
    override fun setChatConfig(chatId: String, config: NewChatConfig) = true.also { calls += "config $chatId ${config.model} ${config.reasoning} ${config.modelOptions}" }
    override fun setChatCheckout(chatId: String, cwd: String, branch: String) = true
    override fun createChat(deviceId: String, spaceId: String?, cwd: String, config: NewChatConfig, branch: String?) =
        "new-chat".also { calls += "create $deviceId $spaceId $cwd ${config.harness} $branch" }
    override fun createSpace(deviceId: String, path: String, gitDetected: Boolean) = "new-space".also { calls += "space $deviceId $path" }
    override fun deleteChat(chatId: String) {}
    override fun deleteSpace(spaceId: String) {}
    override fun foregrounded() { calls += "foreground" }
    override fun flush() { calls += "flush" }
    override fun stop() {}
}

private fun chatRecord(id: String, lastMessageAt: Long? = null, seen: Long? = null) = ChatRecord(
    id = id, deviceId = "mac", title = "Title $id", archived = false, cwd = "/r", branch = "main", checkoutId = null,
    config = ChatConfigRecord("graff", "m1", "high", mapOf("speed" to "fast"), null), lastMessagePreview = "hi",
    lastMessageAt = lastMessageAt, createdAt = 1, spaceId = "s1", lastSeenAt = seen, roomGen = 2, lastPromptAt = null,
)

private fun workspace(chats: List<ChatRecord>, pinned: List<String> = emptyList()) = WorkspaceSnapshot(
    devices = listOf(DeviceRecord("mac", "Studio", "macos", 5, 1, "0.2.109", listOf("message-queue-v1"))),
    spaces = listOf(SpaceRecord("s1", "mac", "/r", null, true, null, null, 1)),
    chats = chats,
    sessions = listOf(SessionRowRecord("a", "mac", SessionStatusRecord.WORKING, 900_000, 990_000)),
    pinnedSessionIds = pinned,
    pinsInitialized = true,
    desktopAppearance = null,
    presence = mapOf("mac" to 999_000L),
    connected = true,
    synced = true,
)

private fun text(id: String, body: String, status: MessageStatusRecord? = MessageStatusRecord.COMPLETE) =
    MessageEntryRecord(id, MessageRoleRecord.ASSISTANT, listOf(MessagePartRecord.Text("$id-t", body)), 1, "mac", status)

@OptIn(ExperimentalCoroutinesApi::class)
class LiveSyncTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)

    @After fun tearDown() = Dispatchers.resetMain()

    private fun live(): Triple<AppModel, FakeCore, LiveFeed> {
        val core = FakeCore()
        val feed = LiveFeed()
        val model = AppModel(clock = { 1_000_000L }, tickMs = 1, liveSync = LiveSync(core, feed))
        return Triple(model, core, feed)
    }

    @Test
    fun aLiveModelStartsEmptyAndUnsyncedThenShowsTheRegistry() = runTest(dispatcher) {
        val (model, core, feed) = live()
        assertTrue(model.isLive)
        assertTrue(model.state.workspace.chats.isEmpty())
        assertFalse(model.state.workspace.synced)
        advanceUntilIdle()
        assertTrue(core.started)

        feed.workspaceChanged(workspace(listOf(chatRecord("a", lastMessageAt = 10, seen = 5), chatRecord("b")), pinned = listOf("b")))
        advanceUntilIdle()
        val ws = model.state.workspace
        assertEquals(listOf("b", "a"), ws.overviewChats.map { it.id })
        assertEquals("Studio", ws.deviceName("mac"))
        assertTrue("a beat 1s ago is online", ws.deviceOnline("mac"))
        assertEquals(ChatIndicator.Working, ws.indicator(ws.chat("a")!!))
        assertEquals(ChatConfig("graff", "m1", "high", mapOf("speed" to "fast")), ws.chat("a")!!.config)
        assertEquals(listOf("message-queue-v1"), ws.devices.single().capabilities)
    }

    @Test
    fun registryWritesGoToTheCoreInsteadOfTheDemo() = runTest(dispatcher) {
        val (model, core, feed) = live()
        feed.workspaceChanged(workspace(listOf(chatRecord("a"))))
        advanceUntilIdle()
        model.archive("a")
        model.unarchive("a")
        model.setPinned("a", true)
        model.markSeen("a")
        model.setChatConfig("a", "m2", "low")
        val space = model.state.workspace.spaces.single()
        assertEquals("new-chat", model.createChat(space, ChatConfig("graff"), "feature", null))
        assertEquals("new-chat", model.createProjectlessChat("mac", ChatConfig("codex")))
        assertEquals("new-space", model.createSpace("mac", " /x ", null))
        assertEquals(
            listOf(
                "archive a true", "archive a false", "pin a true", "seen a",
                "config a m2 low {speed=fast}",
                "create mac s1 /r graff feature", "create mac null ~ codex null", "space mac /x",
            ),
            core.calls,
        )
        // The model never edits the mirror itself: the core's next projection is the truth.
        assertFalse(model.state.workspace.chat("a")!!.archived)
    }

    @Test
    fun aSessionScreenOpensAndClosesTheChatAndOnlyThatChatIsRemapped() = runTest(dispatcher) {
        val (model, core, feed) = live()
        model.attachSession("a")
        model.detachSession("a")
        advanceUntilIdle()
        assertTrue("close a" in core.calls)

        feed.sessionChanged(SessionSnapshot("a", listOf(text("e1", "one"), text("e2", "two", MessageStatusRecord.STREAMING)), emptyList(), true, null, false))
        feed.sessionChanged(SessionSnapshot("b", listOf(text("e9", "other")), emptyList(), true, null, false))
        advanceUntilIdle()
        val firstA = model.entries("a")
        val firstB = model.entries("b")
        assertEquals(2, firstA.size)

        // A token streams into a: b's list is untouched, and a's settled entry keeps its identity.
        feed.sessionChanged(SessionSnapshot("a", listOf(text("e1", "one"), text("e2", "two more", MessageStatusRecord.STREAMING)), emptyList(), true, null, false))
        advanceUntilIdle()
        assertSame(firstB, model.entries("b"))
        assertSame(firstA[0], model.entries("a")[0])
        assertEquals(MessagePart.Text("e2-t", "two more"), model.entries("a")[1].parts.single())
    }

    @Test
    fun theQueueComesFromTheDoc() = runTest(dispatcher) {
        val (model, _, feed) = live()
        feed.sessionChanged(
            SessionSnapshot(
                "a", emptyList(),
                listOf(QueuedMessageRecord("q1", "later", emptyList(), "mac", 3, null, true, QueueDeliveryGateRecord.Editing("mac", 9))),
                true, null, false,
            ),
        )
        advanceUntilIdle()
        val row = model.queue("a").rows.single()
        assertEquals("later", row.text)
        assertTrue(row.holdForTurnEnd)
        assertEquals(QueueDeliveryGate.Editing("mac", 9), row.deliveryGate)
    }

    @Test
    fun lifecycleReachesTheCore() = runTest(dispatcher) {
        val (model, core, _) = live()
        model.foregrounded()
        model.backgrounded()
        advanceUntilIdle()
        Thread.sleep(50) // the flush runs on the IO dispatcher
        assertEquals(listOf("foreground", "flush"), core.calls.filter { it == "foreground" || it == "flush" })
    }

    @Test
    fun partsMapOntoTheTranscriptModel() {
        val tool = MessagePartRecord.Tool(
            "t", "applyPatch",
            mapOf(
                "changes" to ToolFieldRecord.Items(listOf("""{"path":"a,b"}""", """{"path":"c"}""")),
                "ok" to ToolFieldRecord.Flag(true),
                "code" to ToolFieldRecord.Number(3),
                "items" to ToolFieldRecord.Tasks(listOf(TaskItemRecord("x", true))),
            ),
            false, true,
        ).toModel() as MessagePart.Tool
        assertEquals("2 files", tool.call.chipDetail, "a comma inside a change must not change the count")
        assertEquals("true", tool.call.fields["ok"])
        assertEquals("3", tool.call.fields["code"])
        assertEquals(listOf("x"), tool.call.lists["items"])
        assertEquals(
            MessagePart.Image("i", "/tmp/a.png", "a.png", "image/png"),
            MessagePartRecord.Image("i", "/tmp/a.png", "a.png", "image/png").toModel(),
        )
        assertEquals(SessionStatus.AwaitingInput, SessionStatusRecord.AWAITING_INPUT.toModel())
    }

    private fun assertEquals(expected: Any?, actual: Any?, message: String) = org.junit.Assert.assertEquals(message, expected, actual)
}

class DuplicateEntryTest {
    @org.junit.Test
    fun aRepeatedEntryIdRendersOnceInsteadOfCrashingTheList() {
        val entry = harness.codegraff.android.model.MessageEntry(
            "a2", harness.codegraff.android.model.MessageRole.Assistant,
            listOf(MessagePart.Text("t", "hello")), 1, "mac", harness.codegraff.android.model.MessageStatus.Complete,
        )
        val rows = harness.codegraff.android.model.TranscriptRowBuilder.rows(listOf(entry, entry.copy(parts = listOf(MessagePart.Text("t", "again")))))
        assertEquals(rows.map { it.id }.distinct(), rows.map { it.id })
        assertEquals(1, rows.size)
    }
}
