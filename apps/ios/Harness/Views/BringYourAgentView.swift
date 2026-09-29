// "Bring in your agent" (BringYourAgent.kt on Android): what Home shows while nothing has been started, until one of
// Graff, Claude Code or OpenAI Codex is ready on a computer that is online. Harness runs the agent on the computer and
// this app is the remote, so it says what each computer has, what is missing, and, with no computer at all, how to get
// the download link onto one. The rules are in AgentReadiness; the copy is pinned in apps/parity/ux-contract.json.

import SwiftUI

struct BringYourAgentView: View {
    @Environment(AppModel.self) private var model
    @State private var readiness: AgentReadiness?

    private let downloadURL = URL(string: AgentReadiness.downloadURL)!

    var body: some View {
        Group {
            // Until the first answer, and once an agent is ready, Home keeps its plain empty line.
            if let readiness, readiness.state != .ready {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if readiness.state == .noComputer { getHarness }
                    agentCards(readiness)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-agents")
            } else {
                Text("No sessions yet — start one with +")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textFaint)
                    .accessibilityIdentifier("home-empty")
            }
        }
        // Look again while it is on screen: an agent installed or switched on at the computer shows up here.
        .task {
            while !Task.isCancelled {
                readiness = await model.agentReadiness()
                try? await Task.sleep(for: .seconds(readiness?.state == .ready ? 30 : 4))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bring in your agent")
                .font(Theme.sans(22, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Harness runs your agent on your computer, and this app is the remote. Add one of these there, then start a session from here.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// No computer online: the link that gets Harness onto one, ready to AirDrop, message or mail to yourself.
    private var getHarness: some View {
        SheetCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Get Harness on your computer")
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Open the link on your computer, install Harness, and sign in with the same CodeGraff account. Your computer shows up here once it's online.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ShareLink(item: downloadURL, message: Text("Get Harness for your computer")) {
                        Label("Send the link to your computer", systemImage: "square.and.arrow.up")
                            .font(Theme.sans(14, weight: .semibold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Theme.text, in: Capsule())
                    }
                    .accessibilityIdentifier("onboarding-share-link")
                    Button {
                        UIPasteboard.general.url = downloadURL
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Text("Copy link")
                            .font(Theme.sans(14, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("onboarding-copy-link")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func agentCards(_ readiness: AgentReadiness) -> some View {
        SheetCard {
            ForEach(Array(readiness.rows.enumerated()), id: \.element.agent.id) { index, row in
                if index > 0 { SheetSeparator() }
                agentRow(row, noComputer: readiness.state == .noComputer)
            }
        }
    }

    private func agentRow(_ row: AgentReadiness.Row, noComputer: Bool) -> some View {
        let (headline, hint) = describe(row, noComputer: noComputer)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.status == .ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(row.status == .ready ? Theme.text : Theme.textFaint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.agent.name)
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(row.agent.blurb)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(headline)
                    .font(Theme.sans(12.5, weight: .medium))
                    .foregroundStyle(row.status == .ready ? Theme.text : Theme.textMuted)
                    .padding(.top, 2)
                if let hint {
                    Text(hint)
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-agent-\(row.agent.id)")
        .accessibilityValue(row.status.wireName)
    }

    /// What to say about one agent: where it stands, and the one thing to do about it.
    private func describe(_ row: AgentReadiness.Row, noComputer: Bool) -> (String, String?) {
        if noComputer { return ("Needs a computer", nil) }
        let names = row.deviceIds.map(model.deviceName).joined(separator: ", ")
        func on(_ prefix: String) -> String { "\(prefix) \(names)" }
        switch row.status {
        case .ready:
            return (on("Ready on"), nil)
        case .off:
            return (on("Switched off on"), "Turn it on in Settings → Agents on that computer.")
        case .canInstall:
            return (on("Not installed on"), "Install it from Settings → Agents on that computer.")
        case .missing:
            return (on("Not found on"), "Install it on that computer and it will appear here.")
        }
    }
}
