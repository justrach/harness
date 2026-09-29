package harness.codegraff.android

import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.compactAge
import harness.codegraff.android.model.sortedByCalledAt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun sortsNewestCalledFirst() {
        val sorted = listOf(chat("old", created = 1), chat("new", created = 9), chat("mid", created = 5)).sortedByCalledAt()
        assertEquals(listOf("new", "mid", "old"), sorted.map { it.id })
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
    fun compactAgeBuckets() {
        val now = 1_000_000_000L
        assertEquals("now", compactAge(now - 2_000, now))
        assertEquals("40s", compactAge(now - 40_000, now))
        assertEquals("2m", compactAge(now - 120_000, now))
        assertEquals("3h", compactAge(now - 3 * 3_600_000, now))
        assertEquals("5d", compactAge(now - 5 * 86_400_000, now))
        assertEquals("now", compactAge(now + 10_000, now))
    }
}
