package harness.codegraff.android

import harness.codegraff.android.model.MessageEntry
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.TranscriptBuilderCache
import harness.codegraff.android.ui.session.RowVeil
import harness.codegraff.android.ui.session.VeilStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The invariants that keep a long, streaming transcript cheap. */
class ResponsivenessTest {
    private fun assistant(id: String, text: String, status: MessageStatus = MessageStatus.Complete) =
        MessageEntry(id, MessageRole.Assistant, listOf(MessagePart.Text("t0", text)), 1, "d", status)

    private fun user(id: String, text: String) =
        MessageEntry(id, MessageRole.User, listOf(MessagePart.Text("t0", text)), 1, "d", MessageStatus.Complete)

    private fun history(turns: Int): List<MessageEntry> =
        (0 until turns).flatMap { listOf(user("u$it", "question $it"), assistant("a$it", "Answer $it.\n\n- one\n- two\n\n```kotlin\nval x = $it\n```")) }

    @Test
    fun aSettledPartIsParsedExactlyOnce() {
        val cache = TranscriptBuilderCache()
        val entries = history(40)
        cache.rows(entries)
        val afterFirst = cache.parseCount
        assertEquals(40, afterFirst) // one parse per assistant part; user rows are not markdown
        cache.rows(entries.toList()) // a new list with the same content
        assertEquals(afterFirst, cache.parseCount)
    }

    @Test
    fun aStreamedTokenReparsesOnlyTheLiveTail() {
        val cache = TranscriptBuilderCache()
        val settled = history(40)
        var text = "Here is"
        cache.rows(settled + assistant("live", text, MessageStatus.Streaming))
        val before = cache.parseCount
        repeat(25) { i ->
            text += " word$i"
            cache.rows(settled + assistant("live", text, MessageStatus.Streaming))
        }
        // 25 tokens, 25 parses: none of the 40 settled answers were touched.
        assertEquals(before + 25, cache.parseCount)
    }

    @Test
    fun unchangedRowsKeepTheirIdentitySoTheListCanSkipThem() {
        val cache = TranscriptBuilderCache()
        val settled = history(3)
        val first = cache.rows(settled + assistant("live", "a", MessageStatus.Streaming))
        val second = cache.rows(settled + assistant("live", "a b", MessageStatus.Streaming))
        val byId = first.associateBy { it.id }
        for (row in second) {
            if (row.entryId == "live") assertNotSame(byId[row.id], row) else assertSame("row ${row.id} was rebuilt", byId[row.id], row)
        }
    }

    @Test
    fun theSameEntriesInstanceIsServedFromCacheWithoutBuilding() {
        val cache = TranscriptBuilderCache()
        val entries = history(5)
        val rows = cache.rows(entries)
        assertSame(rows, cache.rows(entries))
    }

    @Test
    fun memosForVanishedPartsAreDropped() {
        val cache = TranscriptBuilderCache()
        cache.rows(history(10))
        val parsedWithAll = cache.parseCount
        cache.rows(history(2))
        cache.rows(history(10)) // the dropped parts must be parsed again, proving they were released
        assertTrue(cache.parseCount > parsedWithAll)
    }

    // ---- veil ----

    private class FakeClock(var ms: Double = 0.0) : () -> Double { override fun invoke() = ms }

    @Test
    fun aRowSeenForTheFirstTimeNeverFadesWhatIsAlreadyOnScreen() {
        val clock = FakeClock()
        val veil = RowVeil(seededLength = 40, clock = clock)
        assertFalse(veil.isFading)
        assertEquals(listOf(RowVeil.Segment(0, 40, 1f)), veil.segments(40))
    }

    @Test
    fun appendedTextFadesInAndSettles() {
        val clock = FakeClock(1_000.0)
        val veil = RowVeil(seededLength = 10, clock = clock)
        veil.noteLength(16)
        assertTrue(veil.isFading)
        val start = veil.segments(16)
        assertEquals(listOf(0 to 10, 10 to 16), start.map { it.start to it.end })
        assertEquals(1f, start[0].alpha, 0f)
        assertEquals(0f, start[1].alpha, 0f) // the new chunk starts invisible
        clock.ms += 60.0
        val mid = veil.segments(16)[1].alpha
        assertTrue(mid > 0f && mid < 1f)
        clock.ms += 500.0
        assertFalse(veil.isFading)
        assertEquals(1f, veil.segments(16).last().alpha, 0f)
    }

    @Test
    fun theFadeCurveHasAFastAttackAndASoftLanding() {
        assertEquals(0.0, RowVeil.opacity(0.0), 1e-9)
        assertEquals(1.0, RowVeil.opacity(1.0), 1e-9)
        assertTrue(RowVeil.opacity(0.5) > 0.6) // most of the alpha arrives in the first half
    }

    @Test
    fun aSteadyStreamKeepsTheFadeWithinTheCadenceBounds() {
        val clock = FakeClock(0.0)
        val veil = RowVeil(clock = clock)
        var length = 0
        repeat(40) { length += 3; veil.noteLength(length); clock.ms += 30.0 }
        // Fast appends never stretch a fade past the 400ms cap (plus the small concurrency boost).
        clock.ms += 400.0 * 1.6
        assertFalse(veil.isFading)
    }

    @Test
    fun theStoreKeepsOneClockPerRowAndSeedsFirstSight() {
        val store = VeilStore()
        val a = store.veil("row", 12)
        assertFalse(a.isFading)
        assertSame(a, store.veil("row", 20))
        assertTrue(a.isFading)
    }
}
