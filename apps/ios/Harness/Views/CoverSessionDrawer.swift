// The Duo cover display's sessions drawer pushes the whole navigation page left.
// Back, the title, transcript and composer travel together; the drawer gets its own native rail.

import SwiftUI

enum CoverSessionDrawer {
    static func isAvailable(duo: Bool, compactWidth: Bool, fold: FoldSplit) -> Bool {
        duo && compactWidth && fold == .none
    }

    /// The drawer's full navigation width, including its native control rail.
    /// Keep a tappable sliver of the previous page visible rather than resizing that page.
    static func width(in available: CGFloat) -> CGFloat {
        max(0, available - min(64, available * 0.18))
    }

    static func chatOffset(shown: Bool, width: CGFloat) -> CGFloat {
        shown ? -Self.width(in: width) : 0
    }
}

extension EnvironmentValues {
    /// Only on the Duo cover display. Set by Home, used by the session's native vertical toolbar.
    @Entry var toggleCoverSessions: (() -> Void)? = nil
    @Entry var coverSessionsShown = false
    /// Home's drawer and the pager share selection without pushing another navigation destination.
    @Entry var coverSessionSelection: Binding<String?>? = nil
}

/// Home's rows and ordering. The reveal host supplies a sibling navigation stack, not a nested one.
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

struct CoverSessionDrawerContainer<Page: View, Drawer: View>: View {
    let available: Bool
    let shown: Bool
    let close: () -> Void
    let snapshot: CoverPageSnapshot
    @ViewBuilder var page: Page
    @ViewBuilder var drawer: Drawer

    var body: some View {
        GeometryReader { proxy in
            let open = available && shown
            let drawerWidth = CoverSessionDrawer.width(in: proxy.size.width)
            ZStack(alignment: .trailing) {
                // Keep the live navigation stack mounted in its original geometry.
                // Its native rail would reflow if the live stack crossed the window edge.
                page
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(CoverPageSnapshotSource(snapshot: snapshot).accessibilityHidden(true))
                    .opacity(snapshot.image == nil ? 1 : 0)
                    .accessibilityHidden(snapshot.image != nil)
                    .allowsHitTesting(!open)
                if let image = snapshot.image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .offset(x: CoverSessionDrawer.chatOffset(shown: open, width: proxy.size.width))
                        .transition(.asymmetric(insertion: .offset(x: drawerWidth), removal: .identity))
                        .allowsHitTesting(false)
                        .accessibilityLabel("Current session preview")
                        .accessibilityIdentifier("cover-moving-page")
                }
                if open {
                    HStack(spacing: 0) {
                        Button(action: close) {
                            Color.black.opacity(0.12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Return to current session")
                        .accessibilityIdentifier("cover-sessions-backdrop")
                        drawer
                            .frame(width: drawerWidth)
                            .background(Theme.surface)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24))
                            .shadow(color: .black.opacity(0.12), radius: 16, x: -4)
                            .accessibilityAddTraits(.isModal)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(.escape, close)
                    .accessibilityIdentifier("cover-sessions-drawer")
                    // Both pages travel exactly the same distance, in one transaction.
                    .transition(.offset(x: drawerWidth))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        // Each sibling navigation stack reserves its own native control rail.
        .ignoresSafeArea(.container)
        .animation(Motion.collapse, value: available && shown)
    }
}
