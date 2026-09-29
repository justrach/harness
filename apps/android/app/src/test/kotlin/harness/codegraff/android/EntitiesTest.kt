package harness.codegraff.android

import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.DeviceRow
import harness.codegraff.android.model.SESSION_STALE_MS
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.chatIndicator
import harness.codegraff.android.model.effectiveStatus
import harness.codegraff.android.model.relativeTime
import harness.codegraff.android.model.sortActive
import harness.codegraff.android.model.sortPinnedFirst
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EntitiesTest {
    private fun chat(id: String, created: Long = 0, message: Long? = null, seen: Long? = null, prompt: Long? = null) =
        Chat(id = id, deviceId = "d", createdAt = created, lastMessageAt = message, lastSeenAt = seen, lastPromptAt = prompt)

    @Test
    fun unseenWhenMessageArrivedAfterSeenMark() {
        assertTrue(chat("a", message = 10, seen = 5).unseen)
        assertFalse(chat("a", message = 10, seen = 10).unseen)
        assertTrue(chat("a", message = 10, seen = null).unseen)
        assertFalse(chat("a", message = null).unseen)
    }

    @Test
    fun calledAtPrefersPromptThenMessageThenCreation() {
        assertEquals(30, chat("a", created = 10, message = 20, prompt = 30).calledAt)
        assertEquals(20, chat("a", created = 10, message = 20).calledAt)
        assertEquals(10, chat("a", created = 10).calledAt)
    }

    @Test
    fun sortsByCalledAtNewestFirstWithIdTiebreak() {
        val sorted = sortActive(listOf(chat("old", created = 1), chat("b", created = 5), chat("new", created = 9), chat("a", created = 5)))
        assertEquals(listOf("new", "a", "b", "old"), sorted.map { it.id })
    }

    @Test
    fun pinsSitFirstInTheirOwnOrderThenRecency() {
        val chats = listOf(chat("a", created = 3), chat("b", created = 2), chat("c", created = 1), chat("d", created = 4))
        assertEquals(listOf("c", "a", "d", "b"), sortPinnedFirst(chats, listOf("c", "a", "c", "gone")).map { it.id })
    }

    @Test
    fun displayTitleFallsBackForBlankTitles() {
        assertEquals("New session", chat("a").displayTitle)
        assertEquals("New session", chat("a").copy(title = "").displayTitle)
        assertEquals("Fix it", chat("a").copy(title = "Fix it").displayTitle)
    }

    @Test
    fun spaceDisplayNameFallsBackToFolderBasename() {
        assertEquals("harness", Space("s", "d", "/Users/dev/harness").displayName)
        assertEquals("harness", Space("s", "d", "/Users/dev/harness/").displayName)
        assertEquals("Mine", Space("s", "d", "/x/y", name = "Mine").displayName)
    }

    @Test
    fun onlyDesktopsAndServersHostSessions() {
        assertTrue(DeviceRow("a", "Mac", "macos").canHostSessions)
        assertTrue(DeviceRow("a", "Box", "linux").canHostSessions)
        assertFalse(DeviceRow("a", "Phone", "ios").canHostSessions)
    }

    @Test
    fun staleLiveRowsReadAsIdle() {
        val now = 1_000_000L
        val fresh = SessionRow("c", "d", SessionStatus.Working, updatedAt = now - 1_000)
        val stale = SessionRow("c", "d", SessionStatus.Working, updatedAt = now - SESSION_STALE_MS - 1)
        assertEquals(SessionStatus.Working, effectiveStatus(fresh, now))
        assertNull(effectiveStatus(stale, now))
        assertEquals(SessionStatus.Errored, effectiveStatus(stale.copy(status = SessionStatus.Errored), now))
        assertNull(effectiveStatus(null, now))
    }

    @Test
    fun indicatorFollowsLiveThenUnseen() {
        val read = chat("r", message = 5, seen = 5)
        val unread = chat("u", message = 10, seen = 5)
        assertEquals(ChatIndicator.Working, chatIndicator(read, SessionStatus.Working))
        assertEquals(ChatIndicator.AwaitingInput, chatIndicator(read, SessionStatus.AwaitingInput))
        assertEquals(ChatIndicator.Idle, chatIndicator(read, SessionStatus.Errored))
        assertEquals(ChatIndicator.Errored, chatIndicator(unread, SessionStatus.Errored))
        assertEquals(ChatIndicator.Completed, chatIndicator(unread, null))
        assertEquals(ChatIndicator.Idle, chatIndicator(read, null))
    }

    @Test
    fun relativeTimeBuckets() {
        val now = 1_000_000_000L
        assertEquals("now", relativeTime(now - 40_000, now))
        assertEquals("2m", relativeTime(now - 120_000, now))
        assertEquals("3h", relativeTime(now - 3 * 3_600_000, now))
        assertEquals("5d", relativeTime(now - 5 * 86_400_000, now))
        assertEquals("now", relativeTime(now + 10_000, now))
    }
}
