// iPhone Duo half open (upright, the fold across), with a session open: the layout's measurements and the
// approval helpers. The views are in DuoV3 (the chat above the hinge, Inspect below).

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

// MARK: - Half-open control pad

/// Half open, the lower half is for hands: four big buttons by default, the
/// work view one tap away. Less to read on the keyboard side of the fold.
enum DuoHalfPanel: Equatable {
    case controls
    case work

    enum Control: String, CaseIterable, Identifiable {
        case stop, showChanges, terminal, talk
        var id: String { rawValue }

        var title: String {
            switch self {
            case .stop: return "Stop"
            case .showChanges: return "Show changes"
            case .terminal: return "Terminal"
            case .talk: return "Talk to Graff"
            }
        }

        var symbol: String {
            switch self {
            case .stop: return "stop.fill"
            case .showChanges: return "doc.text.magnifyingglass"
            case .terminal: return "terminal"
            case .talk: return "text.bubble"
            }
        }

        /// Stop only does something while a turn runs; the rest always work.
        func enabled(running: Bool) -> Bool { self == .stop ? running : true }

        /// The work segment a control opens, if any.
        var segment: InspectSegment? {
            switch self {
            case .showChanges: return .diff
            case .terminal: return .terminal
            case .stop, .talk: return nil
            }
        }
    }
}

struct DuoControlPad: View {
    let running: Bool
    let perform: (DuoHalfPanel.Control) -> Void

    var body: some View {
        let controls = DuoHalfPanel.Control.allCases
        VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(controls[(row * 2)..<(row * 2 + 2)]) { control in button(control) }
                }
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
        .accessibilityIdentifier("duo-control-pad")
    }

    private func button(_ control: DuoHalfPanel.Control) -> some View {
        let enabled = control.enabled(running: running)
        let primary = control == .stop && running
        return Button { perform(control) } label: {
            VStack(spacing: 8) {
                Image(systemName: control.symbol).font(.system(size: 22, weight: .semibold))
                Text(control.title).font(Theme.sans(16, weight: .semibold))
            }
            .foregroundStyle(primary ? Theme.bg : Theme.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 88)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(primary ? Theme.danger : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: primary ? 0 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressWashButtonStyle(cornerRadius: 16))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier("duo-control-\(control.rawValue)")
    }
}
