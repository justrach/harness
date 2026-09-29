package harness.codegraff.android.perf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PerfRecorderTest {
    @Test fun percentilesUseNearestRank() {
        val r = PerfRecorder()
        (1..100).forEach { r.record("op", it.toDouble()) }
        val s = r.stats().single()
        assertEquals(100, s.count)
        assertEquals(50.0, s.p50, 0.0)
        assertEquals(95.0, s.p95, 0.0)
        assertEquals(100.0, s.max, 0.0)
    }

    @Test fun windowKeepsOnlyTheLatestRunsButCountsAll() {
        val r = PerfRecorder(capacity = 4)
        listOf(100.0, 1.0, 2.0, 3.0, 4.0).forEach { r.record("op", it) }
        val s = r.stats().single()
        assertEquals(5, s.count)
        // The 100 fell out of the window, so it no longer drags the median or 95th up; it stays in max and total.
        assertEquals(4.0, s.p95, 0.0)
        assertEquals(100.0, s.max, 0.0)
        assertEquals(110.0, s.totalMs, 0.0)
    }

    @Test fun overBudgetRunsAreCounted() {
        val r = PerfRecorder()
        r.record("op", 3.0, budgetMs = 4.0)
        r.record("op", 9.0, budgetMs = 4.0)
        r.record("op", 4.0, budgetMs = 4.0)
        assertEquals(1, r.stats().single().overBudget)
    }

    @Test fun costliestOperationComesFirst() {
        val r = PerfRecorder()
        r.record("cheap", 1.0)
        r.record("costly", 50.0)
        assertEquals(listOf("costly", "cheap"), r.stats().map { it.name })
    }

    @Test fun emptyRecorderHasNoStats() {
        assertTrue(PerfRecorder().stats().isEmpty())
        assertEquals(0.0, PerfRecorder.percentile(DoubleArray(0), 0.5), 0.0)
    }

    @Test fun resetClears() {
        val r = PerfRecorder()
        r.record("op", 1.0)
        r.reset()
        assertTrue(r.stats().isEmpty())
    }

    @Test fun slowFramesAreBlamedOnTheirLongestStage() {
        val t = FrameTally()
        val layoutHeavy = DoubleArray(FrameStage.entries.size).also { it[FrameStage.Layout.ordinal] = 20.0; it[FrameStage.Draw.ordinal] = 3.0 }
        val drawHeavy = DoubleArray(FrameStage.entries.size).also { it[FrameStage.Draw.ordinal] = 18.0 }
        val quick = DoubleArray(FrameStage.entries.size).also { it[FrameStage.Draw.ordinal] = 4.0 }
        t.add(24.0, layoutHeavy, 16.7)
        t.add(25.0, layoutHeavy, 16.7)
        t.add(19.0, drawHeavy, 16.7)
        t.add(5.0, quick, 16.7)
        val s = t.snapshot()
        assertEquals(4, s.frames)
        assertEquals(3, s.slow)
        assertEquals(0, s.frozen)
        assertEquals(listOf(FrameStage.Layout to 2L, FrameStage.Draw to 1L), s.slowFramesBlamedOn)
        assertEquals(75.0, s.slowPercent, 0.0)
    }

    @Test fun frozenFramesAreCountedSeparately() {
        val t = FrameTally()
        t.add(800.0, DoubleArray(FrameStage.entries.size), 16.7)
        val s = t.snapshot()
        assertEquals(1, s.frozen)
        assertEquals(1, s.slow)
    }
}
