// Session switcher — the phone's answer to the desktop's side-by-side panes.
// A floating glass pill shows the sessions you're juggling as a row of status
// dots; tapping it lists them, and picking one jumps straight there.
//
// Like panes, a session keeps its place: the order is when you last called
// each one (the Home order), and a run finishing only changes its dot.

import SwiftUI

extension EnvironmentValues {
    /// Open a session from anywhere under Home. From inside a session it
    /// replaces that session rather than stacking another one behind it.
    @Entry var switchToSession: ((String) -> Void)? = nil
}

/// The sessions you're juggling, in the order you last called them: anything
/// running or waiting on you, plus what you called recently, so a session that
/// finished and was read stays put instead of vanishing.
struct JuggledSessions {
    /// A session called this recently stays even once it's idle.
    static let recentWindowMs: Int64 = 3 * 60 * 60 * 1000
    static let limit = 10

    var chats: [Chat] = []
    var indicators: [String: ChatIndicator] = [:]

    @MainActor
    init(model: AppModel) {
        let now = nowMs()
        for chat in sortActive(model.overviewChats) {
            let indicator = model.indicator(for: chat)
            guard indicator != .idle || now - chat.calledAt < Self.recentWindowMs else { continue }
            chats.append(chat)
            indicators[chat.id] = indicator
            if chats.count == Self.limit { break }
        }
    }

    func others(than chatId: String?) -> [Chat] { chats.filter { $0.id != chatId } }

    func count(_ matches: (ChatIndicator) -> Bool, excluding chatId: String?) -> Int {
        others(than: chatId).filter { matches(indicators[$0.id] ?? .idle) }.count
    }
}

/// Floating glass pill: one status dot per juggled session, in order, with
/// the open one ringed. Home adds "2 need you · 1 running"; the session
/// screen keeps just the dots, sharing the bottom with the composer.
struct SessionSwitcherPill: View {
    @Environment(AppModel.self) private var model
    var current: String?
    var compact = false
    @State private var showSheet = false

    private static let maxDots = 6

    var body: some View {
        let _ = model.connectivity.pulse
        let juggled = JuggledSessions(model: model)
        let hasOthers = !juggled.others(than: current).isEmpty
        Group {
            if hasOthers {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showSheet = true
                } label: {
                    HStack(spacing: 10) {
                        dots(juggled)
                        if !compact, let summary = summary(juggled) {
                            Text(summary)
                                .font(Theme.sans(14, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Theme.text)
                        }
                    }
                    .padding(.horizontal, compact ? 12 : 16)
                    .frame(height: compact ? 36 : 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .accessibilityLabel(accessibilityText(juggled))
                .accessibilityIdentifier("session-switcher")
                .pagerSwipe()
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .motionAnimation(Motion.fadeQuick, value: hasOthers)
        .sheet(isPresented: $showSheet) {
            SessionSwitcherSheet(current: current)
        }
    }

    private func dots(_ juggled: JuggledSessions) -> some View {
        let shown = juggled.chats.prefix(Self.maxDots)
        let extra = juggled.chats.count - shown.count
        return HStack(spacing: 5) {
            ForEach(shown) { chat in
                let indicator = juggled.indicators[chat.id] ?? .idle
                statusMark(indicator)
                    .frame(width: 7, height: 7)
                    .padding(2)
                    .overlay {
                        if chat.id == current {
                            Circle().strokeBorder(Theme.text.opacity(0.7), lineWidth: 1.2)
                        }
                    }
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(Theme.sans(12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    /// Running is a ring, needs you a filled dot, finished-and-read a quiet
    /// grey dot: shape carries the state, since some themes paint running
    /// and needs-you in near-identical hues. Colors are the Home chips'.
    @ViewBuilder
    private func statusMark(_ indicator: ChatIndicator) -> some View {
        switch indicator {
        case .working: Circle().strokeBorder(Theme.statusWorking, lineWidth: 1.8)
        case .awaitingInput, .errored, .completed: Circle().fill(Theme.warning)
        case .idle: Circle().fill(ink(0.25))
        }
    }

    private func summary(_ juggled: JuggledSessions) -> String? {
        let needsYou = juggled.count(HomeStatusFilter.attention.matches, excluding: current)
        let running = juggled.count(HomeStatusFilter.running.matches, excluding: current)
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need you") }
        if running > 0 { parts.append("\(running) running") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func accessibilityText(_ juggled: JuggledSessions) -> String {
        let others = juggled.others(than: current).count
        return "\(others) other sessions" + (summary(juggled).map { ", \($0)" } ?? "")
    }
}

/// The pill's list: the juggled sessions in the same order, the open one
/// marked. Picking a row jumps there.
struct SessionSwitcherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.switchToSession) private var switchToSession
    var current: String?

    var body: some View {
        let juggled = JuggledSessions(model: model)
        NavigationStack {
            List {
                Section {
                    ForEach(juggled.chats) { chat in
                        ChatRow(chat: chat, showLocation: true) {
                            dismiss()
                            if chat.id != current { switchToSession?(chat.id) }
                        }
                        .overlay(alignment: .leading) {
                            if chat.id == current {
                                Capsule()
                                    .fill(Theme.text.opacity(0.7))
                                    .frame(width: 3)
                                    .padding(.vertical, 10)
                                    .offset(x: -6)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .accessibilityIdentifier("switcher-\(chat.id)")
                        .accessibilityValue(chat.id == current ? "Open" : "")
                    }
                } footer: {
                    Text("In the order you last called them. Sessions stay while they run or need you, and for a few hours after you last called them.")
                }
            }
            .navigationTitle("Your sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .harnessAppearance()
    }
}
