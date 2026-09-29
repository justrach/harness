package harness.codegraff.android

import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.HarnessCatalog
import harness.codegraff.android.model.HomeFilter
import harness.codegraff.android.model.HomeFilterNames
import harness.codegraff.android.model.HomeGroup
import harness.codegraff.android.model.HomeGroupBy
import harness.codegraff.android.model.HomeGrouping
import harness.codegraff.android.model.HomeStatusFilter
import harness.codegraff.android.model.MessageEntry
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.RenderToolCall
import harness.codegraff.android.model.RowKind
import harness.codegraff.android.model.ToolItem
import harness.codegraff.android.model.TranscriptRowBuilder
import harness.codegraff.android.model.toolGroupSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeAndCatalogTest {
    private fun chat(id: String, title: String, space: String? = null, device: String = "d1", branch: String? = null) =
        Chat(id = id, deviceId = device, title = title, createdAt = 0, spaceId = space, branch = branch)

    @Test
    fun everyWordOfTheQueryHasToMatchSomewhere() {
        val chats = listOf(chat("a", "Fix veil", "s1", "d1"), chat("b", "Fix deploy", "s2", "d2"), chat("c", "Unrelated"))
        val names = { c: Chat -> HomeFilterNames(if (c.spaceId == "s1") "harness" else "edge", if (c.deviceId == "d1") "studio" else "vps") }
        val found = HomeFilter.apply(chats, "harness studio", HomeStatusFilter.All, { ChatIndicator.Idle }, names)
        assertEquals(listOf("a"), found.map { it.id })
        assertEquals(3, HomeFilter.apply(chats, "", HomeStatusFilter.All, { ChatIndicator.Idle }, names).size)
    }

    @Test
    fun statusFiltersMatchTheirIndicators() {
        assertTrue(HomeStatusFilter.Attention.matches(ChatIndicator.Completed))
        assertTrue(HomeStatusFilter.Attention.matches(ChatIndicator.AwaitingInput))
        assertTrue(!HomeStatusFilter.Attention.matches(ChatIndicator.Working))
        assertTrue(HomeStatusFilter.Running.matches(ChatIndicator.Working))
        assertTrue(!HomeStatusFilter.Running.matches(ChatIndicator.Idle))
    }

    @Test
    fun projectGroupsKeepFirstAppearanceOrderAndProjectlessGoLast() {
        val chats = listOf(chat("a", "A"), chat("b", "B", "s2"), chat("c", "C", "s1"), chat("d", "D", "s2"))
        val groups = HomeGrouping.groups(chats, HomeGroupBy.Project)
        assertEquals(listOf("project:s2", "project:s1", "project:"), groups.map { it.id })
        assertEquals(listOf("b", "d"), groups[0].chats.map { it.id })
        assertNull((groups.last().kind as HomeGroup.Kind.Project).spaceId)
        assertEquals(1, HomeGrouping.groups(chats, HomeGroupBy.None).size)
    }

    @Test
    fun claudeCodeDefaultsToTheFirstCatalogModelAndHighEffort() {
        val model = HarnessCatalog.defaultModel("claude-code")
        assertEquals("claude-fable-5-1", model.id)
        assertEquals("high", HarnessCatalog.defaultReasoning(model))
        assertNull(HarnessCatalog.defaultReasoning(HarnessCatalog.models("devin").first()))
    }

    @Test
    fun modelLookupToleratesOneMSuffixesAndUnknownIds() {
        val models = HarnessCatalog.models("claude-code")
        assertEquals("claude-opus-5", HarnessCatalog.resolveExisting("claude-opus-5[1m]", models)?.id)
        assertEquals("Opus 5", HarnessCatalog.modelLabel("claude-code", "claude-opus-5-1m"))
        assertEquals("some-unknown-model", HarnessCatalog.modelLabel("codex", "some-unknown-model"))
    }

    @Test
    fun reasoningLabelsReadLikeTheDesktopPickers() {
        assertEquals("X-High", HarnessCatalog.reasoningLabel("xhigh"))
        assertEquals("Ultrathink", HarnessCatalog.reasoningLabel("ultrathink"))
        assertEquals("Custom", HarnessCatalog.reasoningLabel("custom"))
    }

    // ---- transcript rows ----

    private fun tool(id: String, tag: String, error: Boolean = false) =
        MessagePart.Tool(id, RenderToolCall(tag, mapOf("path" to "a/b/c.rs", "command" to "cargo test")), error, true)

    @Test
    fun toolGroupsSummariseTheWayTheDesktopDoes() {
        val items = listOf(
            ToolItem(RenderToolCall("exec"), isError = true, resolved = true),
            ToolItem(RenderToolCall("editFile"), false, true),
            ToolItem(RenderToolCall("search"), false, true),
        )
        assertEquals("Ran 1 command · edited 1 file · 1 search · 1 failed", toolGroupSummary(items))
    }

    @Test
    fun chipDetailShortensPathsButExpandedKeepsThem() {
        val call = RenderToolCall("readFile", mapOf("path" to "crates/ui/src/veil.rs"))
        assertEquals("src/veil.rs", call.chipDetail)
        assertEquals("crates/ui/src/veil.rs", call.expandedDetail)
    }

    @Test
    fun rowsSplitPerBlockWithStableIdsAndTightBlockGaps() {
        val entry = MessageEntry(
            "m2", MessageRole.Assistant,
            listOf(tool("t1", "search"), tool("t2", "exec", error = true), MessagePart.Text("p0", "One.\n\nTwo.")),
            createdAt = 5, deviceId = "d", status = MessageStatus.Complete,
        )
        val user = MessageEntry("m1", MessageRole.User, listOf(MessagePart.Text("t0", "Hello")), 1, "d", MessageStatus.Complete)
        val rows = TranscriptRowBuilder.rows(listOf(user, entry))
        assertEquals(listOf("m1", "m2#g0", "m2#p0.0", "m2#p0.1"), rows.map { it.id })
        assertTrue(rows[0].kind is RowKind.User)
        assertEquals(26f, rows[0].topGap, 0f) // first row: space-large + 10
        assertEquals(16f, rows[1].topGap, 0f) // a new turn
        assertEquals(12f, rows[2].topGap, 0f) // after a tool stack
        assertEquals(12f, rows[3].topGap, 0f) // sibling blocks of one part
        // Only the last block of a settled part carries the timestamp.
        assertNull(rows[2].timestamp)
        assertEquals(5L, rows[3].timestamp)
    }

    @Test
    fun aStreamingTailKeepsItsToolGroupOpenAndItsLastBlockLive() {
        val entry = MessageEntry(
            "m2", MessageRole.Assistant, listOf(tool("t1", "exec"), MessagePart.Text("p0", "Working…")),
            createdAt = 5, deviceId = "d", status = MessageStatus.Streaming,
        )
        val rows = TranscriptRowBuilder.rows(listOf(entry))
        assertEquals(false, (rows[0].kind as RowKind.ToolGroup).autoOpen)
        assertEquals(true, (rows[1].kind as RowKind.Markdown).streaming)
        val toolTail = entry.copy(parts = listOf(tool("t1", "exec")))
        assertEquals(true, (TranscriptRowBuilder.rows(listOf(toolTail))[0].kind as RowKind.ToolGroup).autoOpen)
    }

    @Test
    fun pendingSendsEchoUntilTheHostAdoptsThem() {
        val pending = harness.codegraff.android.model.PendingSend("u-1", "typed")
        assertEquals("u-1", TranscriptRowBuilder.rows(emptyList(), listOf(pending)).single().id)
        val adopted = MessageEntry("u-1", MessageRole.User, listOf(MessagePart.Text("t0", "typed")), 1, "d", MessageStatus.Complete)
        assertEquals(1, TranscriptRowBuilder.rows(listOf(adopted), listOf(pending)).size)
    }
}
