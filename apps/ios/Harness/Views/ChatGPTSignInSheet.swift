// "Use your ChatGPT plan" (ChatGPTSignInSheet.kt on Android): sign in to ChatGPT so OpenAI Codex's requests run on the
// person's plan. The browser step happens on the computer, so this sheet only picks the computer, starts it there,
// shows the wait and shows the outcome, in the wording OpenAI's guidelines ask for. The rules are in ChatGPTSignIn; the
// copy is pinned in apps/parity/ux-contract.json.

import SwiftUI

struct ChatGPTSignInSheet: View {
    let computers: [ChatGPTComputer]
    let client: any ChatGPTSignInClient

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ChatGPTSignInFlow
    @State private var selected: String

    init(computers: [ChatGPTComputer], client: any ChatGPTSignInClient) {
        self.computers = computers
        self.client = client
        _flow = State(initialValue: ChatGPTSignInFlow(client: client))
        _selected = State(initialValue: computers.first?.id ?? "")
    }

    private var selectedName: String { computers.first { $0.id == selected }?.name ?? "" }
    private var locked: Bool { flow.phase != .idle }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Cancel") { finish() }
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("chatgpt-close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    steps
                    outcome
                }
                .padding(20)
            }
        }
        .background(SheetStyle.panel)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatgpt-sheet")
        .onDisappear { flow.stop() }
        // The confirmation is for the first sign-in with plan usage only; a later one just closes.
        .onChange(of: flow.phase) { _, phase in
            guard phase == .connected else { return }
            model.chatGPTConnected = true
            if model.chatGPTWelcomeSeen { dismiss() } else { model.markChatGPTWelcomeSeen() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Use your ChatGPT plan")
                .font(Theme.sans(22, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("OpenAI Codex can run on your ChatGPT plan. This doesn't give it access to your ChatGPT conversations.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The two things to do, numbered like the sign-in dialogs people already know.
    private var steps: some View {
        SheetCard {
            step(1, "Choose the computer") {
                VStack(spacing: 0) {
                    ForEach(computers) { computer in
                        SheetSelectRow(title: computer.name, selected: computer.id == selected) {
                            if !locked { selected = computer.id }
                        }
                        .accessibilityIdentifier("chatgpt-computer-\(computer.id)")
                    }
                }
                .padding(.horizontal, -16)
            }
            SheetSeparator()
            step(2, "Continue with ChatGPT") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A browser window opens on that computer. Approve it there.")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if flow.phase == .idle {
                        SheetPrimaryButton(title: "Continue with ChatGPT", enabled: !computers.isEmpty) {
                            flow.start(deviceId: selected)
                        }
                        .accessibilityIdentifier("chatgpt-continue")
                    }
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(Theme.sans(13, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Theme.textFaint, lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 2)
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The wait, then what happened.
    @ViewBuilder private var outcome: some View {
        if flow.phase != .idle {
            VStack(alignment: .leading, spacing: 12) {
                if flow.phase == .waiting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(waitingLine)
                            .font(Theme.sans(15, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                    Text("Keep this open until it finishes.")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textMuted)
                } else {
                    let copy = outcomeCopy(flow.phase)
                    Text(copy.title)
                        .font(Theme.sans(17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let body = copy.body {
                        Text(body)
                            .font(Theme.sans(14))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if flow.phase == .connected { ManageUsageButton() }
                }
                actionButton
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chatgpt-status")
            .accessibilityValue(flow.phase.rawValue)
        }
    }

    private var waitingLine: String {
        func on(_ prefix: String) -> String { "\(prefix) \(selectedName)" }
        return on("Waiting for approval on")
    }

    private func outcomeCopy(_ phase: ChatGPTPhase) -> (title: String, body: String?) {
        switch phase {
        case .connected:
            ("You're using your ChatGPT plan",
             "Eligible AI requests in this app use your ChatGPT plan. You can manage usage in ChatGPT settings.")
        case .planUsageOff:
            ("Signed in, but plan usage is off",
             "OpenAI Codex can't use your ChatGPT plan yet. Sign in again and allow plan usage.")
        case .declined: ("You didn't approve the sign-in", "Nothing was changed. Try again when you're ready.")
        case .failed: ("Sign-in didn't finish", "Something went wrong on your computer. Try again.")
        case .idle, .waiting: ("", nil)
        }
    }

    /// The one main button for this screen.
    @ViewBuilder private var actionButton: some View {
        switch ChatGPTSignIn.action(in: flow.phase) {
        case .start:
            EmptyView()
        case .cancel:
            Button("Cancel") { flow.cancel(deviceId: selected) }
                .font(Theme.sans(15, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chatgpt-cancel")
        case .done:
            SheetPrimaryButton(title: "Got it") { finish() }
                .accessibilityIdentifier("chatgpt-done")
        case .retry:
            SheetPrimaryButton(title: flow.phase == .planUsageOff ? "Sign in again" : "Try again") {
                flow.start(deviceId: selected)
            }
            .accessibilityIdentifier("chatgpt-retry")
        }
    }

    private func finish() {
        if flow.phase == .waiting { flow.cancel(deviceId: selected) }
        dismiss()
    }
}
