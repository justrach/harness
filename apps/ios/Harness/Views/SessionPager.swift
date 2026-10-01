// Session pager — swipe the open session's header (or the switcher pill) to
// move to the next or previous session you're juggling, without going back to
// Home. The page set is what's running or waiting on you, plus the open
// session; when nothing else is active it falls back to everything in the
// switcher so the swipe never dead-ends on a quiet day.
//
// The header and pill are the swipe surface on purpose: a full-screen swipe
// would fight the back gesture and horizontal scrolling in code and tables.

import SwiftUI

enum PageDirection {
    case previous, next
}

extension EnvironmentValues {
    /// Page the open session: set by the pager host, nil outside it.
    @Entry var pageSession: ((PageDirection) -> Void)? = nil
}

/// Which session a swipe lands on. Pure, so the rule is testable without UI.
enum SessionPaging {
    struct Entry: Equatable {
        let id: String
        let active: Bool
    }

    /// `entries` are in switcher order (when you last called each session).
    /// Next is the older neighbour, previous the newer one.
    static func neighbors(of current: String, in entries: [Entry]) -> (previous: String?, next: String?) {
        guard entries.contains(where: { $0.id == current }) else { return (nil, nil) }
        var set = entries.filter { $0.active || $0.id == current }
        if set.count < 2 { set = entries }
        guard let index = set.firstIndex(where: { $0.id == current }) else { return (nil, nil) }
        return (index > 0 ? set[index - 1].id : nil,
                index + 1 < set.count ? set[index + 1].id : nil)
    }

    /// 1-based place of `current` in the page set and the set's size, for the
    /// "2 of 4" hint. Nil when there's nothing to page to.
    static func position(of current: String, in entries: [Entry]) -> (index: Int, count: Int)? {
        let n = neighbors(of: current, in: entries)
        guard n.previous != nil || n.next != nil else { return nil }
        var set = entries.filter { $0.active || $0.id == current }
        if set.count < 2 { set = entries }
        guard let index = set.firstIndex(where: { $0.id == current }) else { return nil }
        return (index + 1, set.count)
    }

    @MainActor
    static func entries(model: AppModel) -> [Entry] {
        let juggled = JuggledSessions(model: model)
        return juggled.chats.map {
            Entry(id: $0.id, active: (juggled.indicators[$0.id] ?? .idle) != .idle)
        }
    }
}

/// Hosts the open session so it can swap for a neighbour in place: the new
/// session slides in from the side you swiped toward while the navigation
/// stack stays one level deep (Back still returns to Home).
struct SessionPagerHost: View {
    @Environment(AppModel.self) private var model
    @State private var current: String
    @State private var forward = true

    init(chatId: String) {
        _current = State(initialValue: chatId)
    }

    var body: some View {
        let _ = model.connectivity.pulse
        ZStack {
            SessionView(chatId: current)
                .id(current)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading),
                    removal: .move(edge: forward ? .leading : .trailing)))
        }
        .clipped()
        .environment(\.pageSession, page)
        .environment(\.switchToSession, { go(to: $0) })
    }

    private func page(_ direction: PageDirection) {
        let n = SessionPaging.neighbors(of: current, in: SessionPaging.entries(model: model))
        guard let target = direction == .next ? n.next : n.previous else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.4)
            return
        }
        go(to: target)
    }

    private func go(to chatId: String) {
        guard chatId != current else { return }
        let order = SessionPaging.entries(model: model).map(\.id)
        let from = order.firstIndex(of: current), to = order.firstIndex(of: chatId)
        forward = (from ?? 0) <= (to ?? 0)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.3)) { current = chatId }
    }
}

/// Makes a view the swipe handle: it follows the finger a little, then pages
/// on release; with nowhere to go it springs back.
struct PagerSwipe: ViewModifier {
    @Environment(\.pageSession) private var pageSession
    @State private var dx: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        guard pageSession != nil,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        dx = value.translation.width * 0.35
                    }
                    .onEnded { value in
                        let w = value.translation.width, h = value.translation.height
                        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { dx = 0 }
                        guard let pageSession, abs(w) > 60, abs(w) > abs(h) * 1.5 else { return }
                        pageSession(w < 0 ? .next : .previous)
                    }
            )
    }
}

extension View {
    func pagerSwipe() -> some View { modifier(PagerSwipe()) }
}
