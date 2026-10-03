import SwiftUI

struct AgentReauthenticationSheet: View {
    let provider: AgentReauthProvider
    let hostName: String
    @State private var recovery: AgentReauthentication
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(provider: AgentReauthProvider, hostName: String, relay: DeviceRelayClient?) {
        self.provider = provider
        self.hostName = hostName
        _recovery = State(initialValue: AgentReauthentication(
            transport: relay.map { RelayAgentLoginTransport(relay: $0) }))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Sign in to ChatGPT")
                        .font(Theme.sans(22, weight: .semibold))
                    Text("Credentials will be saved on \(hostName), where this session runs. This does not sign you out of Harness.")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.textMuted)
                    switch recovery.phase {
                    case .idle, .starting:
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Starting sign-in on the execution device…")
                        }
                    case .waiting:
                        if let approval = recovery.approval {
                            Text("Approve sign-in on your iPhone")
                                .font(Theme.sans(16, weight: .medium))
                            Text("Open the sign-in page and enter this code to approve access for \(hostName). Only approve a sign-in you started.")
                                .foregroundStyle(Theme.textMuted)
                            Text(approval.code)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                                .accessibilityLabel("Sign-in code: \(approval.code)")
                            Button("Copy code") {
                                UIPasteboard.general.string = approval.code
                            }
                            Button("Open ChatGPT sign-in") {
                                // Explicit user action; only validated start URLs.
                                openURL(approval.url)
                            }
                            .buttonStyle(.borderedProminent)
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Waiting for approval and host sign-in…")
                            }
                        } else {
                            Text("Complete sign-in on \(hostName)")
                                .font(Theme.sans(16, weight: .medium))
                            Text("This execution device uses desktop sign-in. Complete it in the browser on \(hostName); its local callback cannot finish in this phone's browser.")
                                .foregroundStyle(Theme.textMuted)
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Waiting for desktop sign-in…")
                            }
                        }
                        Text("Credentials are saved on \(hostName), not your iPhone. Sign-in will not resend or replay the failed message.")
                            .foregroundStyle(Theme.textMuted)
                    case .done:
                        Label("Signed in on \(hostName)", systemImage: "checkmark.circle")
                        Text("Return to the session and send or retry your message when you are ready. The failed turn has not been replayed.")
                            .foregroundStyle(Theme.textMuted)
                        Button("Return to session") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    case .failed(let message):
                        Text(message).foregroundStyle(Theme.danger)
                        Button("Try again") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .font(Theme.sans(14))
                .foregroundStyle(Theme.text)
                .padding(24)
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(recovery.phase == .done ? "Close" : "Cancel") {
                        recovery.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: attempt) { await recovery.run(provider: provider) }
        .onDisappear { recovery.cancel() }
    }
}
