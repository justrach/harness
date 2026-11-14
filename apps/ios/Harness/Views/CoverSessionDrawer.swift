// The Duo cover display's session list: a trailing drawer over the chat, not a second cramped column.
// The native toolbar owns the control rail; the drawer stays inside its safe area.

import SwiftUI

enum CoverSessionDrawer {
    static func isAvailable(duo: Bool, compactWidth: Bool, fold: FoldSplit) -> Bool {
        duo && compactWidth && fold == .none
    }

    /// Keep a tappable sliver of the chat visible. Use the safe width, never the status/control rail's inset.
    static func width(in available: CGFloat) -> CGFloat {
        max(0, available - min(64, available * 0.18))
    }
}

extension EnvironmentValues {
    @Entry var coverSessionsAvailable = false
    /// Only on the Duo cover display. Set by the pager, used by the session's native vertical toolbar.
    @Entry var toggleCoverSessions: (() -> Void)? = nil
    @Entry var coverSessionsShown = false
}

/// Home's rows and ordering, without a nested navigation stack (which would replace the native side rail).
struct CoverSessionsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openNewSession) private var openNewSession
    @State private var query = ""
    let current: String
    let close: () -> Void
    let select: (String) -> Void

    private var chats: [Chat] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sortActive(model.overviewChats).filter {
            query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search sessions", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("cover-sessions-search")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close sessions")
                .accessibilityIdentifier("cover-sessions-close")
            }
            .font(Theme.sans(15))
            .padding(.leading, 12)
            .background(Theme.text.opacity(0.05), in: Capsule())
            .padding(12)

            List {
                if let openNewSession {
                    Button {
                        close()
                        openNewSession()
                    } label: {
                        Label("New session", systemImage: "plus")
                            .font(Theme.sans(15, weight: .medium))
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("cover-sessions-new")
                    .listRowBackground(Color.clear)
                }
                ForEach(chats) { chat in
                    ChatRow(chat: chat, showLocation: true) { select(chat.id) }
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(chat.id == current ? Theme.elementActive : Color.clear)
                        .accessibilityIdentifier("cover-session-\(chat.id)")
                        .accessibilityValue(chat.id == current ? "Open" : "")
                }
                if chats.isEmpty {
                    Text(query.isEmpty ? "No sessions yet" : "No matching sessions")
                        .font(Theme.sans(15))
                        .foregroundStyle(Theme.textMuted)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cover-sessions-list")
    }
}

struct CoverSessionDrawerOverlay<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Button(action: close) {
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to current session")
                .accessibilityIdentifier("cover-sessions-backdrop")
                content
                    .frame(width: CoverSessionDrawer.width(in: proxy.size.width))
                    .background(Theme.surface)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24))
                    .shadow(color: .black.opacity(0.12), radius: 16, x: -4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, close)
        .accessibilityIdentifier("cover-sessions-drawer")
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
