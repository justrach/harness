// A Stop tap right after a question closes is ignored for a moment (#149).
// The question panel takes the composer's place, and its Submit sits where
// the composer's Stop shows up once the answer syncs back and the run goes
// on. Without the pause, one more tap on Submit stops the run it just
// resumed. Pinned in apps/parity/vectors/composer-stop.json.

enum StopGuard {
    static let graceMs: Int64 = 1500

    /// Whether a Stop tap at `nowMs` goes through. A clock that went back
    /// never holds Stop off.
    static func allows(nowMs: Int64, questionClosedAtMs: Int64?) -> Bool {
        guard let closed = questionClosedAtMs else { return true }
        return nowMs < closed || nowMs - closed >= graceMs
    }
}
