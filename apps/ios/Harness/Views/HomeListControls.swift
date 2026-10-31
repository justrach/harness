// The two controls above the Home list: which project's sessions it shows, and
// how it groups them. They sit together on one row, as a matched pair of pills,
// so the pair reads as "what this list shows" (#419). The project choice used
// to sit alone in the nav bar as a bare "All", the grouping on a row of its own
// as a bare "Time".

import SwiftUI

enum HomeListControls {
    /// The project pill when no project is chosen. "All" alone didn't say all of what.
    static let allProjectsTitle = "All projects"

    /// The project pill's text: the chosen project's name, or All projects.
    static func scopeTitle(projectName: String?) -> String {
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
}

extension HomeGroupBy {
    /// The grouping pill's text. "By …" says it arranges the list, where a bare
    /// "Time" read like another filter.
    var pillTitle: String {
        switch self {
        case .none: return "By time"
        case .project: return "By project"
        case .device: return "By device"
        }
    }
}

/// One of the Home list's control pills: symbol, title and a chevron in a
/// capsule. Outlined at its default, filled once it narrows or regroups the
/// list, so a changed list is visible at a glance. Text follows Dynamic Type.
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
        // Quiet either way: a faint ink fill under glass, a little deeper when
        // the chip has been changed from its default. No border, no solid fill.
        .background(Capsule().fill(ink(active ? 0.09 : 0.04)))
        .glassEffect(.regular.interactive(), in: Capsule())
        // A 44pt target around the 36pt capsule.
        .frame(minHeight: Theme.hitTarget)
        .contentShape(Rectangle())
    }
}
