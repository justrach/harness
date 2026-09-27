// Session Live Activities: a running agent on the lock screen and in the
// Dynamic Island. The app starts one when a session starts working or needs
// input, keeps it in step while the app runs, and settles it on Done/Failed.
// While the app is suspended the elapsed timer keeps ticking by itself and the
// status catches up on the next foreground.

import ActivityKit
import Foundation

/// One session as the Live Activity sees it.
struct LiveActivitySnapshot: Hashable {
    var attributes: SessionActivityAttributes
    /// nil: the session is idle (nothing to show).
    var phase: SessionActivityAttributes.ContentState.Phase?
    var startedAt: Date
    var detail: String?

    var state: SessionActivityAttributes.ContentState? {
        phase.map { .init(phase: $0, startedAt: startedAt, detail: detail) }
    }
}

enum LiveActivityPlan {
    /// iOS caps concurrent activities per app; three keeps the lock screen
    /// readable.
    static let maxLive = 3

    enum Step: Equatable {
        case start(chatId: String)
        case update(chatId: String)
        /// Settle on the final state and leave it up for a while.
        case finish(chatId: String)
        /// The session went idle (seen, or gone): take it down now.
        case remove(chatId: String)
    }

    /// The latest line, flattened to one short line for the island.
    static func detail(_ preview: String?) -> String? {
        guard let preview else { return nil }
        let line = preview.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 140 ? String(line.prefix(139)) + "…" : line
    }

    static func phase(for indicator: ChatIndicator) -> SessionActivityAttributes.ContentState.Phase? {
        switch indicator {
        case .working: return .working
        case .awaitingInput: return .waiting
        case .completed: return .done
        case .errored: return .failed
        case .idle: return nil
        }
    }

    /// What to do given the activities already showing (chat id → the state
    /// they show). New activities only start for running or waiting
    /// sessions, most recent first, up to `maxLive`.
    static func steps(showing: [String: SessionActivityAttributes.ContentState],
                      sessions: [LiveActivitySnapshot]) -> [Step] {
        var steps: [Step] = []
        let byId = Dictionary(sessions.map { ($0.attributes.chatId, $0) },
                              uniquingKeysWith: { first, _ in first })
        for (chatId, shown) in showing.sorted(by: { $0.key < $1.key }) {
            guard let session = byId[chatId], let next = session.state else {
                steps.append(.remove(chatId: chatId))
                continue
            }
            if next.phase == .done || next.phase == .failed {
                steps.append(.finish(chatId: chatId))
            } else if next != shown {
                steps.append(.update(chatId: chatId))
            }
        }
        var live = showing.count - steps.filter {
            if case .remove = $0 { return true }
            if case .finish = $0 { return true }
            return false
        }.count
        let candidates = sessions
            .filter { showing[$0.attributes.chatId] == nil && ($0.phase == .working || $0.phase == .waiting) }
            .sorted { ($0.startedAt, $0.attributes.chatId) > ($1.startedAt, $1.attributes.chatId) }
        for session in candidates where live < maxLive {
            steps.append(.start(chatId: session.attributes.chatId))
            live += 1
        }
        return steps
    }
}

@MainActor
final class LiveActivities {
    private var activities: [String: Activity<SessionActivityAttributes>] = [:]
    /// Last push to each activity. A streaming reply changes the latest line
    /// many times a second; those land at most every few seconds.
    private var lastUpdate: [String: Date] = [:]
    private static let detailInterval: TimeInterval = 5

    init() {
        // Adopt activities from an earlier launch instead of doubling them.
        for activity in Activity<SessionActivityAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
            activities[activity.attributes.chatId] = activity
        }
    }

    func sync(_ sessions: [LiveActivitySnapshot]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let showing = activities.mapValues { $0.content.state }
        let byId = Dictionary(sessions.map { ($0.attributes.chatId, $0) },
                              uniquingKeysWith: { first, _ in first })
        for step in LiveActivityPlan.steps(showing: showing, sessions: sessions) {
            switch step {
            case .start(let chatId):
                guard let session = byId[chatId], let state = session.state else { continue }
                if let activity = try? Activity.request(attributes: session.attributes,
                                                        content: Self.content(state), pushType: nil) {
                    activities[chatId] = activity
                    lastUpdate[chatId] = .now
                }
            case .update(let chatId):
                guard let activity = activities[chatId], let state = byId[chatId]?.state else { continue }
                let shown = activity.content.state
                let onlyDetail = shown.phase == state.phase && shown.startedAt == state.startedAt
                if onlyDetail, let last = lastUpdate[chatId],
                   Date.now.timeIntervalSince(last) < Self.detailInterval {
                    continue
                }
                lastUpdate[chatId] = .now
                Task { await activity.update(Self.content(state)) }
            case .finish(let chatId):
                guard let activity = activities.removeValue(forKey: chatId),
                      let state = byId[chatId]?.state else { continue }
                lastUpdate[chatId] = nil
                Task {
                    await activity.end(Self.content(state),
                                       dismissalPolicy: .after(.now.addingTimeInterval(20 * 60)))
                }
            case .remove(let chatId):
                guard let activity = activities.removeValue(forKey: chatId) else { continue }
                lastUpdate[chatId] = nil
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    private static func content(_ state: SessionActivityAttributes.ContentState)
        -> ActivityContent<SessionActivityAttributes.ContentState> {
        // A running state that stops updating (app suspended, no push yet)
        // greys out after half an hour rather than claiming to be live.
        let stale: Date? = state.phase == .working ? .now.addingTimeInterval(30 * 60) : nil
        return ActivityContent(state: state, staleDate: stale)
    }
}
