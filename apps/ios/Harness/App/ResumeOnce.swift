// Resumes one continuation exactly once, from whichever of several threads gets there first (an observation
// change, a task cancellation). A continuation resumed twice traps and one never resumed hangs its task, so
// the "install" and "fire" orders are both handled: firing before the continuation exists resumes it the
// moment it is installed.

import Foundation

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if fired {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
