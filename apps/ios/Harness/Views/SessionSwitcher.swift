// Session switcher — the phone's answer to the desktop's side-by-side panes.
// A floating glass pill counts the other sessions that need you or are still
// running; tapping it lists them, and picking one jumps straight there.

import SwiftUI

extension EnvironmentValues {
    /// Open a session from anywhere under Home. From inside a session it
    /// replaces that session rather than stacking another one behind it.
    @Entry var switchToSession: ((String) -> Void)? = nil
}

/// The sessions worth a glance, excluding the one on screen.
struct ActiveSessions {
    /// A question, a failure, or a finished run not yet looked at — most
    /// urgent first.
    var needsYou: [Chat] = []
    var running: [Chat] = []

    var isEmpty: Bool { needsYou.isEmpty && running.isEmpty }

    @MainActor
    init(model: AppModel, excluding chatId: String? = nil) {
        var needsYou: [(Chat, ChatIndicator)] = []
        for chat in model.overviewChats where chat.id != chatId {
            let indicator = model.indicator(for: chat)
            switch indicator {
            case .awaitingInput, .errored, .completed: needsYou.append((chat, indicator))
            case .working: running.append(chat)
            case .idle: break
            }
        }
        // Stable: within one status the list's own order stands.
        self.needsYou = needsYou.enumerated()
            .sorted { ($0.element.1.rawValue, $0.offset) < ($1.element.1.rawValue, $1.offset) }
            .map(\.element.0)
    }
}

/// Floating glass pill: "● 2 need you · ● 3 running", in the Home status
/// chips' colors. `compact` drops the words for the session screen, where it
/// shares the bottom with the composer.
struct SessionSwitcherPill: View {
    @Environment(AppModel.self) private var model
    var excluding: String?
    var compact = false
    @State private var showSheet = false

    var body: some View {
        let _ = model.connectivity.pulse
        let active = ActiveSessions(model: model, excluding: excluding)
        Group {
            if !active.isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showSheet = true
                } label: {
                    HStack(spacing: compact ? 8 : 10) {
                        if !active.needsYou.isEmpty {
                            count(active.needsYou.count, color: Theme.warning,
                                  word: "need you")
                        }
                        if !active.needsYou.isEmpty, !active.running.isEmpty, !compact {
                            Text("·").foregroundStyle(Theme.textFaint)
                        }
                        if !active.running.isEmpty {
                            count(active.running.count, color: Theme.statusWorking,
                                  word: "running")
                        }
                    }
                    .font(Theme.sans(compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, compact ? 12 : 16)
                    .frame(height: compact ? 36 : 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .accessibilityLabel(accessibilityText(active))
                .accessibilityIdentifier("session-switcher")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .motionAnimation(Motion.fadeQuick, value: active.isEmpty)
        .sheet(isPresented: $showSheet) {
            SessionSwitcherSheet(excluding: excluding)
        }
    }

    private func count(_ n: Int, color: Color, word: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(compact ? "\(n)" : "\(n) \(word)").monospacedDigit()
        }
    }

    private func accessibilityText(_ active: ActiveSessions) -> String {
        var parts: [String] = []
        if !active.needsYou.isEmpty { parts.append("\(active.needsYou.count) need you") }
        if !active.running.isEmpty { parts.append("\(active.running.count) running") }
        return "Sessions: " + parts.joined(separator: ", ")
    }
}

/// The pill's list: Needs you, then Running. Picking a row jumps there.
struct SessionSwitcherSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.switchToSession) private var switchToSession
    var excluding: String?

    var body: some View {
        let active = ActiveSessions(model: model, excluding: excluding)
        NavigationStack {
            List {
                if active.isEmpty {
                    Text("Nothing else is running or waiting on you.")
                        .foregroundStyle(Theme.textMuted)
                }
                if !active.needsYou.isEmpty {
                    Section("Needs you") { rows(active.needsYou) }
                }
                if !active.running.isEmpty {
                    Section("Running") { rows(active.running) }
                }
            }
            .navigationTitle("Active sessions")
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

    private func rows(_ chats: [Chat]) -> some View {
        ForEach(chats) { chat in
            ChatRow(chat: chat, showLocation: true) {
                dismiss()
                switchToSession?(chat.id)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .accessibilityIdentifier("switcher-\(chat.id)")
        }
    }
}
