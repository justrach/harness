// Where the next message goes: the latest chat, one of the recent ones, or a
// new chat.

import SwiftUI

struct ChatPickerView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Row(selected: store.target == .newChat, pick: { store.target = .newChat }) {
                    HStack(spacing: 9) {
                        ZStack {
                            Circle().fill(WatchTheme.accentWash).frame(width: 26, height: 26)
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(WatchTheme.accent)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New chat")
                                .font(WatchTheme.sans(15, .medium))
                                .foregroundStyle(WatchTheme.text)
                            Text("Auto models")
                                .font(WatchTheme.sans(12))
                                .foregroundStyle(WatchTheme.muted)
                        }
                    }
                }
                if !store.chats.isEmpty {
                    Text("RECENT")
                        .font(WatchTheme.eyebrow())
                        .tracking(0.8)
                        .foregroundStyle(WatchTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                }
                ForEach(store.chats) { chat in
                    Row(selected: store.target != .newChat && store.targetChat?.id == chat.id, pick: {
                        // The newest chat follows whatever is called next.
                        store.target = chat.id == store.chats.first?.id ? .latest : .chat(chat.id)
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.title)
                                .font(WatchTheme.sans(14, .medium))
                                .foregroundStyle(WatchTheme.text)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            StatusLabel(status: chat.status)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .background(WatchTheme.bg.ignoresSafeArea())
        .navigationTitle {
            Text("Send to").font(WatchTheme.sans(15, .semibold)).foregroundStyle(WatchTheme.accent)
        }
    }

    /// A card row; the chosen one is outlined in amber with a check.
    private struct Row<Content: View>: View {
        @Environment(\.dismiss) private var dismiss
        let selected: Bool
        let pick: () -> Void
        @ViewBuilder let content: Content

        var body: some View {
            Button {
                pick()
                WatchTheme.haptic(.click)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    content
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(WatchTheme.accent)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(stroke: selected ? WatchTheme.accent.opacity(0.7) : WatchTheme.border)
            }
            .buttonStyle(.plain)
        }
    }
}
