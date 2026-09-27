// A session's Live Activity (lock screen + Dynamic Island). Compiled into
// both the app, which starts and updates it, and the widget extension, which
// draws it.

import ActivityKit
import Foundation

struct SessionActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case working, waiting, done, failed
        }

        var phase: Phase
        /// When the current run started; the working timer counts from here
        /// on its own, so it stays live while the app is suspended.
        var startedAt: Date
    }

    var chatId: String
    var title: String
    /// "project @ device".
    var location: String
    /// Index into the project tint palette (`Theme.projectTint`); nil for
    /// projectless sessions.
    var projectTint: Int?

    /// Tapping the activity opens the session.
    var url: URL? {
        var components = URLComponents()
        components.scheme = "harness"
        components.host = "chat"
        components.path = "/" + chatId
        return components.url
    }
}
