// iPhone Duo half open like a laptop, with a session open. The upper half watches the work (the live
// terminal, or the diff) in 14pt mono and takes no input; the lower half is where you act: the composer and
// the quick actions. While typing, the keyboard covers the lower half, so the actions and the composer move
// up to sit right above it and the watch pane gives them the room. The session list comes in on demand from
// the header (FoldPaneHeader).

import Combine
import SwiftUI

/// The fold in laptop pose, measured from the top of the window: the upper half's height and the hinge.
struct DuoLaptopLayout: Equatable {
    var top: CGFloat
    var gap: CGFloat
}

extension EnvironmentValues {
    /// Set on a session opened in laptop pose (HomeView); nil everywhere else.
    @Entry var duoLaptop: DuoLaptopLayout? = nil
    /// The mono face Inspect's diff and terminal use; the laptop's watch pane reads at 14pt.
    @Entry var inspectMono: Font = DuoType.mono
}

// MARK: - Quick actions

enum QuickAction: String, CaseIterable, Identifiable {
    case approve, retry, stop, runTests
    var id: String { rawValue }

    var title: String {
        switch self {
        case .approve: "Approve"
        case .retry: "Retry"
        case .stop: "Stop"
        case .runTests: "Run tests"
        }
    }

    var symbol: String {
        switch self {
        case .approve: "checkmark"
        case .retry: "arrow.clockwise"
        case .stop: "stop.fill"
        case .runTests: "checklist"
        }
    }
}

enum QuickActions {
    /// What Run tests sends. The agent knows the project's test command; the phone does not.
    static let runTestsPrompt = "Run the tests and tell me what fails."

    /// Whether an action can run now. A running turn can only be stopped; an idle one can be retried or
    /// asked to run the tests; Approve needs a question it can answer.
    static func enabled(_ action: QuickAction, running: Bool, approvable: Bool, hasPrompt: Bool) -> Bool {
        switch action {
        case .approve: approvable
        case .retry: !running && hasPrompt
        case .stop: running
        case .runTests: !running
        }
    }

    /// Approve answers every open question with its first option (the agent puts the yes first), and only
    /// when each question is a single choice with options. Anything else needs the full panel.
    static func approval(_ questions: [UserInputQuestion]) -> [UserInputAnswer]? {
        guard !questions.isEmpty else { return nil }
        var answers: [UserInputAnswer] = []
        for question in questions {
            guard question.multiSelect != true, let first = question.options.first else { return nil }
            answers.append(UserInputAnswer(questionId: question.id, labels: [first]))
        }
        return answers
    }

    /// The prompt Retry sends again: the text of the newest message the person sent.
    static func lastPrompt(_ entries: [MessageEntry]) -> String? {
        for entry in entries.reversed() where entry.role == .user {
            let text = entry.parts.compactMap { part -> String? in
                if case .text(_, let text) = part { return text }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}

/// Approve, Retry, Stop, Run tests. Solid, not glass: they sit on the work, and only the pill and the
/// switcher float.
struct QuickActionsRow: View {
    let enabled: (QuickAction) -> Bool
    let perform: (QuickAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(QuickAction.allCases) { action in
                let on = enabled(action)
                Button { perform(action) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.symbol).font(.system(size: 12, weight: .semibold))
                        Text(action.title).font(DuoType.sans(small: true, medium: true))
                    }
                    .foregroundStyle(action == .stop && on ? Theme.danger : Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.surfaceRaised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!on)
                .opacity(on ? 1 : 0.4)
                .accessibilityIdentifier("quick-\(action.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-actions")
    }
}

// MARK: - Watch pane

/// The upper half: the live terminal, or the diff, read-only, in 14pt mono.
struct LaptopWatchPane: View {
    let model: InspectModel
    @Bindable var state: InspectState
    let running: Bool

    /// Files is Inspect's third segment; the watch pane shows the diff in its place.
    private var showsTerminal: Bool { state.segment == .terminal }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("Terminal", on: showsTerminal) { state.segment = .terminal }
                tab("Diff", on: !showsTerminal) { state.segment = .diff }
                Spacer(minLength: 8)
                if running {
                    Circle().fill(Theme.statusCompleted).frame(width: 6, height: 6)
                    Text("Live").font(DuoType.sans(small: true)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Rectangle().fill(Theme.border).frame(height: 1)
            Group {
                if showsTerminal {
                    InspectTerminalView(commands: model.commands, state: state)
                } else {
                    InspectDiffView(files: model.files, state: state)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.inspectMono, Theme.mono(14))
        }
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("laptop-watch")
    }

    private func tab(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DuoType.sans(small: true, medium: true))
                .foregroundStyle(on ? Theme.text : Theme.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(on ? Theme.text.opacity(0.08) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("laptop-watch-\(title.lowercased())")
    }
}

// MARK: - Keyboard

/// How far the keyboard reaches into a view, in points. Laptop pose ignores the keyboard's safe area (it
/// lands below the fold), so the composer is lifted by hand only while it is the one typing.
struct KeyboardOverlap: ViewModifier {
    @Binding var overlap: CGFloat
    @State private var maxY: CGFloat = 0
    @State private var keyboardTop: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                maxY = $0
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                keyboardTop = frame.minY
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardTop = nil
                update()
            }
    }

    private func update() {
        let next = keyboardTop.map { max(0, maxY - $0) } ?? 0
        if next != overlap { withAnimation(Motion.collapse) { overlap = next } }
    }
}
