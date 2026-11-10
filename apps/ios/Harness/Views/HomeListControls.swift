// The two controls above the Home list: which project's sessions it shows, and
// how it groups them. They sit together on one row, as a matched pair of pills,
// so the pair reads as "what this list shows" (#419). The project choice used
// to sit alone in the nav bar as a bare "All", the grouping on a row of its own
// as a bare "Time".

import SwiftUI

enum HomeListControls {
    /// The project pill when no project is chosen. "All" alone didn't say all of what.
    static let allProjectsTitle = "All projects"

    /// The saved filter value for sessions outside any project. Space ids are
    /// never empty or start with "~", so it can't collide with one; "" stays All.
    static let projectlessFilter = "~projectless"
    static let projectlessTitle = "No project"

    /// Sessions with no project (desktop `sidebar_chats` with `Some("")`).
    static func projectless(_ chats: [Chat]) -> [Chat] {
        chats.filter { $0.spaceId == nil }
    }

    /// The project pill's text: the chosen project's name, No project, or All projects.
    static func scopeTitle(projectName: String?, projectless: Bool = false) -> String {
        if projectless { return projectlessTitle }
        guard let projectName, !projectName.isEmpty else { return allProjectsTitle }
        return projectName
    }

    /// The row shows while there is anything to scope: a session, a project to
    /// pick, or a project already picked. The last keeps the way out of a
    /// project that has no sessions yet.
    static func showsRow(hasSessions: Bool, hasProjects: Bool, projectSelected: Bool) -> Bool {
        hasSessions || hasProjects || projectSelected
    }

    /// Grouping only means something when the scope has sessions to group.
    static func showsGrouping(sessionsInScope: Int) -> Bool {
        sessionsInScope > 0
    }

    /// Top-of-screen clutter (`HomeStartHeader`, `PinnedRow`, `SplitOfferBanner`,
    /// `NowStrip`) stays off the Home list (`FrameSchedule.lean`:
    /// `clean_home_layout_has_zero_top_clutter`), so the filter pills and
    /// session rows open immediately at the top of the screen.
    static func showsTopClutter(hasSessions: Bool) -> Bool {
        false
    }
}

/// Time-window filter matching the desktop sidebar's `Last activity` menu
/// (`FrameSchedule.lean`: `keepChatFixed`).
enum HomeActivityWindow: String, CaseIterable, Identifiable {
    case d1 = "1d"
    case d3 = "3d"
    case d7 = "7d"
    case d30 = "30d"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .d1: return "1d"
        case .d3: return "3d"
        case .d7: return "7d"
        case .d30: return "30d"
        case .all: return "All"
        }
    }

    var cutoffMs: Int64? {
        let dayMs: Int64 = 86_400_000
        switch self {
        case .d1: return dayMs
        case .d3: return 3 * dayMs
        case .d7: return 7 * dayMs
        case .d30: return 30 * dayMs
        case .all: return nil
        }
    }

    static func keep(_ chat: Chat, indicator: ChatIndicator, window: HomeActivityWindow, nowMs: Int64) -> Bool {
        guard let cutoff = window.cutoffMs else { return true }
        if indicator == .working || indicator == .awaitingInput { return true }
        let touched = max(chat.lastMessageAt ?? 0, chat.createdAt)
        return touched >= nowMs - cutoff
    }

    static func apply(_ chats: [Chat], window: HomeActivityWindow,
                      indicator: (Chat) -> ChatIndicator, nowMs: Int64) -> [Chat] {
        guard window != .all else { return chats }
        return chats.filter { keep($0, indicator: indicator($0), window: window, nowMs: nowMs) }
    }
}

extension HomeGroupBy {
    /// The grouping pill's text. "By …" says it arranges the list, where a bare
    /// "Time" read like another filter.
    var pillTitle: String {
        switch self {
        case .status: return "By status"
        case .none: return "By time"
        case .project: return "By project"
        case .device: return "By device"
        }
    }
}

/// One of the Home list's control pills: symbol, title and a chevron in a
/// capsule. Pure native Liquid Glass (`FrameSchedule.lean`:
/// `native_glass_preserves_specular_refraction`) without an interior ink wash
/// or border overlay, matching the system's own toolbar and search bar glass.
struct HomeControlPill: View {
    let symbol: String
    let title: String
    /// Changed from its default (a project chosen, or grouped).
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.sans(Theme.previewSize, weight: active ? .semibold : .regular, relativeTo: .subheadline))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)
        }
        .foregroundStyle(active ? Theme.text : Theme.textMuted)
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.chipHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
        // A 44pt target around the 36pt capsule.
        .frame(minHeight: Theme.hitTarget)
        .contentShape(Rectangle())
    }
}
