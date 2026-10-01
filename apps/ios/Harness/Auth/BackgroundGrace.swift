// A short lease of background time for one small piece of work. A token refresh that iOS suspends
// between the edge rotating the credential and the new one reaching the Keychain would strand the
// phone with a spent credential, so a refresh in flight asks to be allowed to finish.

import UIKit

final class BackgroundGrace: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var ended = false

    @MainActor
    static func begin(_ name: String) -> BackgroundGrace {
        let grace = BackgroundGrace()
        grace.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { grace.end() }
        return grace
    }

    func end() {
        lock.lock()
        let id = identifier
        let already = ended
        ended = true
        lock.unlock()
        guard !already, id != .invalid else { return }
        Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
    }
}
