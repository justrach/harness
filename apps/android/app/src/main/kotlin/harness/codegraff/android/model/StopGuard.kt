package harness.codegraff.android.model

/**
 * A Stop tap right after a question closes is ignored for a moment (#149). The question panel takes the composer's
 * place, and its Submit sits where the composer's Stop shows up once the answer syncs back and the run goes on. Without
 * the pause, one more tap on Submit stops the run it just resumed. iOS `StopGuard`; pinned in
 * `apps/parity/vectors/composer-stop.json`.
 */
object StopGuard {
    const val GRACE_MS = 1_500L

    /** Whether a Stop tap at [nowMs] goes through. A clock that went back never holds Stop off. */
    fun allows(nowMs: Long, questionClosedAtMs: Long?): Boolean {
        val closed = questionClosedAtMs ?: return true
        return nowMs < closed || nowMs - closed >= GRACE_MS
    }
}
