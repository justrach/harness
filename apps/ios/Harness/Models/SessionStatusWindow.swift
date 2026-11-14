import Foundation

/// A bounded, ordered window of status marks. The open session stays visible;
/// the overflow label counts every omitted session, including those before it.
struct SessionStatusWindow {
    let visibleIDs: [String]
    let hiddenCount: Int

    init(ids: [String], current: String, limit: Int) {
        let count = min(ids.count, max(0, limit))
        let index = ids.firstIndex(of: current) ?? 0
        let start = min(max(0, index - count / 2), ids.count - count)
        visibleIDs = Array(ids[start..<(start + count)])
        hiddenCount = ids.count - count
    }

    var overflowText: String? { hiddenCount > 0 ? "+\(hiddenCount)" : nil }

    /// Reserve title space and only the navigation that is actually rendered.
    /// Compact overflow leaves room for more status marks and the session title.
    static func visibleLimit(availableWidth: CGFloat, total: Int, hasPager: Bool) -> Int {
        guard total > 0 else { return 0 }
        // Both the current index and total can grow to multiple digits.
        let counterWidth = CGFloat(String(total).count * 2 + 1) * 7
        let navigationWidth: CGFloat = hasPager ? 56 + counterWidth + 7 : 7
        let budget = availableWidth - 120 - navigationWidth
        for count in stride(from: min(6, total), through: 1, by: -1) {
            let marksWidth = CGFloat(count * 16 + (count - 1) * 3)
            let overflowWidth: CGFloat = total > count ? 3 + CGFloat(String(total - count).count + 1) * 7 : 0
            if marksWidth + overflowWidth <= budget { return count }
        }
        return 1
    }

    /// Staleness grace for a persisted `.streaming` entry when no live session row confirms the run.
    static let staleStreamGraceMs: Int64 = sessionStaleMs

    /// True only while a mid-stream turn has a live run backing it. A stale persisted `.streaming`
    /// entry whose host is offline or whose session has no live `.working` run returns `false`
    /// so it never claims to be `Running` forever.
    static func hasLiveMidStreamTurn(
        entries: [MessageEntry],
        liveStatus: SessionStatus?,
        hostStatus: HostStatus = .online,
        nowMs: Int64 = Harness.nowMs(),
        staleAfterMs: Int64 = staleStreamGraceMs
    ) -> Bool {
        guard let streamingEntry = entries.last(where: { $0.status == .streaming }) else {
            return false
        }
        if hostStatus == .offline {
            return false
        }
        if let liveStatus {
            return liveStatus == .working
        }
        let age = nowMs - streamingEntry.createdAt
        return age <= staleAfterMs
    }

    /// Returns the live `.streaming` entry only if backed by a live run, else `nil`.
    static func liveStreamingEntry(
        in entries: [MessageEntry],
        liveStatus: SessionStatus?,
        hostStatus: HostStatus = .online,
        nowMs: Int64 = Harness.nowMs(),
        staleAfterMs: Int64 = staleStreamGraceMs
    ) -> MessageEntry? {
        guard hasLiveMidStreamTurn(
            entries: entries,
            liveStatus: liveStatus,
            hostStatus: hostStatus,
            nowMs: nowMs,
            staleAfterMs: staleAfterMs
        ) else {
            return nil
        }
        return entries.last(where: { $0.status == .streaming })
    }

    /// Resolves a chat's display indicator, preventing a stale persisted mid-stream turn
    /// from keeping the session in `.working` (`Running`) when the host/session has no live run.
    static func resolvedIndicator(
        chat: Chat,
        sessionRow: SessionRow?,
        entries: [MessageEntry],
        hostStatus: HostStatus = .online,
        nowMs: Int64 = Harness.nowMs(),
        staleAfterMs: Int64 = staleStreamGraceMs
    ) -> ChatIndicator {
        let live = effectiveStatus(sessionRow, now: nowMs)
        let base = chatIndicator(chat: chat, live: live)
        if base == .working && hostStatus == .offline {
            return chat.unseen ? .completed : .idle
        }
        if base != .working,
           hasLiveMidStreamTurn(
               entries: entries,
               liveStatus: live,
               hostStatus: hostStatus,
               nowMs: nowMs,
               staleAfterMs: staleAfterMs
           ) {
            return .working
        }
        return base
    }
}
