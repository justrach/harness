import SwiftUI

struct AgentReauthenticationSheet: View {
    let provider: AgentReauthProvider
    let hostName: String
    /// The host verified the renewed sign-in: the row that opened the sheet is resolved.
    var onSignedIn: () -> Void = {}
    /// Resume the conversation (a new turn in the same chat), or nil when it can't be offered.
    /// Returns false when nothing was sent.
    var resume: (() -> Bool)? = nil
    @State private var recovery: AgentReauthentication
    @State private var attempt = 0
    @State private var browsing = false
    @State private var pasted = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(provider: AgentReauthProvider, hostName: String, relay: DeviceRelayClient?,
         onSignedIn: @escaping () -> Void = {}, resume: (() -> Bool)? = nil) {
        self.provider = provider
        self.hostName = hostName
        self.onSignedIn = onSignedIn
        self.resume = resume
        _recovery = State(initialValue: AgentReauthentication(
            transport: relay.map { RelayAgentLoginTransport(relay: $0) }))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Reconnect ChatGPT")
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
                        } else if let signIn = recovery.browserSignIn {
                            phoneSignIn(signIn)
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
                        Label("ChatGPT reconnected on \(hostName)", systemImage: "checkmark.circle")
                        Text("Nothing was resent. Resume the conversation when you're ready, or go back and send something new.")
                            .foregroundStyle(Theme.textMuted)
                        if let resume {
                            Button("Resume conversation") {
                                if resume() { dismiss() }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("agent-reauth-resume")
                            Button("Return to session") { dismiss() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Return to session") { dismiss() }
                                .buttonStyle(.borderedProminent)
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(Theme.danger)
                        Button(provider == .chatGPTNew ? "Continue with ChatGPT" : "Try again") { attempt += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                    if recovery.phase != .done {
                        Text(ReauthCopy.accountSecurityNote)
                            .font(Theme.sans(12))
                            .foregroundStyle(Theme.textMuted)
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
        .onChange(of: recovery.phase) { _, phase in
            if phase == .done { onSignedIn() }
        }
        // Dismissal only stops watching: the sign-in keeps waiting on the host, and reopening
        // attaches to it. The Cancel button is the explicit way to end it.
        .onDisappear { recovery.detach() }
        .sheet(isPresented: $browsing) {
            if let signIn = recovery.browserSignIn {
                ChatGPTSignInBrowser(signIn: signIn) { redirect in
                    Task { await recovery.finish(redirect: redirect) }
                }
            }
        }
    }

    /// graff's ChatGPT sign-in finished here: in the in-app browser, or in Safari
    /// for accounts whose provider blocks in-app sign-in (Google), then pasting
    /// the address of the page that didn't load.
    @ViewBuilder
    private func phoneSignIn(_ signIn: AgentReauthentication.BrowserSignIn) -> some View {
        if recovery.handedOff {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finishing sign-in on \(hostName)…")
            }
        } else {
            Text("Sign in on your iPhone")
                .font(Theme.sans(16, weight: .medium))
            Text("Sign in to ChatGPT here and allow access for \(hostName). Only continue with a sign-in you started.")
                .foregroundStyle(Theme.textMuted)
            Button("Sign in with ChatGPT") { browsing = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agent-reauth-phone-browser")
            if let error = recovery.redirectError {
                Text(error).foregroundStyle(Theme.danger)
            }
            DisclosureGroup("Signing in with Google?") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Google doesn't allow sign-in inside apps. Open the page in Safari, sign in, and when Safari says it can't open the final page, copy that page's address and paste it here.")
                        .foregroundStyle(Theme.textMuted)
                    Button("Open in Safari") { openURL(signIn.url) }
                    TextField("Address of the page that didn't load", text: $pasted)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("agent-reauth-pasted-redirect")
                    Button("Finish sign-in") {
                        let redirect = pasted
                        Task {
                            if await recovery.finish(redirect: redirect) { pasted = "" }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 8)
            }
        }
    }
}
