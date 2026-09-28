// Home list search and status filter. Both narrow the same recency-ordered
// list the grouping splits into sections, so a search inside "Project"
// grouping still reads by project.

import SwiftUI

enum HomeStatusFilter: String, CaseIterable, Identifiable {
    case all, attention, running

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .attention: return "Needs you"
        case .running: return "Running"
        }
    }

    /// Needs you: a question, an error, or a finished run not yet looked at.
    func matches(_ indicator: ChatIndicator) -> Bool {
        switch self {
        case .all: return true
        case .attention: return indicator == .awaitingInput || indicator == .errored || indicator == .completed
        case .running: return indicator == .working
        }
    }
}

enum HomeFilter {
    /// Names a session is searchable by that live outside the chat itself.
    struct Names {
        var project: String?
        var device: String
    }

    /// Sessions whose status matches and whose title, last message, branch,
    /// folder, project or device contains every word of `query`.
    static func apply(_ chats: [Chat], query: String, status: HomeStatusFilter,
                      indicator: (Chat) -> ChatIndicator,
                      names: (Chat) -> Names) -> [Chat] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return chats.filter { chat in
            guard status.matches(indicator(chat)) else { return false }
            guard !terms.isEmpty else { return true }
            let extra = names(chat)
            let fields = [chat.displayTitle, chat.lastMessagePreview, chat.branch,
                          chat.cwd.map { ($0 as NSString).lastPathComponent },
                          extra.project, extra.device].compactMap { $0 }
            // Every word has to appear somewhere: "harness studio" finds the
            // harness sessions on the studio, not every session on either.
            return terms.allSatisfy { term in
                fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }
}

/// All · Needs you · Running, with live counts. Sits above the list.
struct HomeStatusChips: View {
    @Binding var selection: HomeStatusFilter
    let counts: [HomeStatusFilter: Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HomeStatusFilter.allCases) { filter in
                chip(filter)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ filter: HomeStatusFilter) -> some View {
        let selected = selection == filter
        let count = counts[filter] ?? 0
        return Button {
            withAnimation(Motion.resort) {
                // Tapping the active chip again clears it.
                selection = selected && filter != .all ? .all : filter
            }
        } label: {
            HStack(spacing: 5) {
                if filter != .all {
                    Circle()
                        .fill(filter == .running ? Theme.statusWorking : Theme.warning)
                        .frame(width: 6, height: 6)
                }
                Text(filter.label)
                    .font(Theme.sans(13, weight: selected ? .semibold : .medium))
                if filter != .all, count > 0 {
                    Text("\(count)")
                        .font(Theme.sans(12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Theme.text : Theme.textFaint)
                }
            }
            .foregroundStyle(selected ? Theme.text : Theme.textMuted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(selected ? Theme.elementActive : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-status-\(filter.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
