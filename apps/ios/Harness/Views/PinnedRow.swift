// The pinned row: pinned sessions as avatars across the top of Home, between
// the title and the chips, like pinned conversations in a messages list. One
// tap opens the session. Shown only while something is pinned and the list
// isn't being searched.

import SwiftUI

struct PinnedRow: View {
    @Environment(AppModel.self) private var model
    let chats: [Chat]
    let open: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(chats) { chat in
                    PinnedItem(chat: chat, indicator: model.indicator(for: chat)) { open(chat.id) }
                }
            }
        }
        .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned sessions")
        .accessibilityIdentifier("pinned-row")
    }
}

private struct PinnedItem: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let indicator: ChatIndicator
    let action: () -> Void

    /// The status dot on the avatar's corner: running, waiting, failed, or an
    /// unread reply in the accent. Idle sessions carry none.
    private var dot: Color? {
        switch indicator {
        case .working: return Theme.statusWorking
        case .awaitingInput: return Theme.warning
        case .errored: return Theme.danger
        case .completed: return Theme.accent
        case .idle: return nil
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AgentAvatar(harness: chat.config?.harness, size: Theme.pinnedAvatar)
                    .overlay(alignment: .topTrailing) {
                        if let dot {
                            Circle()
                                .fill(dot)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2.5))
                                .offset(x: 1, y: -1)
                        }
                    }
                Text(chat.displayTitle)
                    .font(Theme.sans(Theme.metaSize))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                withAnimation(Motion.resort) { model.setPinned(chatId: chat.id, pinned: false) }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
        }
        .accessibilityLabel(chat.displayTitle)
        .accessibilityValue(indicator.label ?? "")
        .accessibilityIdentifier("pinned-\(chat.id)")
    }
}
