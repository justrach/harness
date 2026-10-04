// Settings > Usage. Spend and limits live with the computers that run the
// agents, so this asks one of them over its relay: the CodeGraff account its
// engine is signed in with (credits, 30-day spend, the monthly key budget)
// and each agent CLI's plan windows (Claude Code, Codex, …). The desktop's
// Settings → Accounts shows the same numbers.

import SwiftUI

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDeviceId: String?
    @State private var state: LoadState = .idle
    @State private var now = Date()

    enum LoadState {
        case idle
        case loading
        case loaded(codegraff: CodegraffUsage?, accounts: [AgentAccount])
        case failed(String)
    }

    /// Computers that can run agents, online ones first.
    private var hosts: [DeviceRow] {
        let candidates = model.devices.filter(\.canHostSessions)
        return candidates.filter { model.deviceOnline($0.id) }
            + candidates.filter { !model.deviceOnline($0.id) }
    }

    private var deviceId: String? {
        if let selectedDeviceId, hosts.contains(where: { $0.id == selectedDeviceId }) {
            return selectedDeviceId
        }
        return hosts.first?.id
    }

    var body: some View {
        List {
            if hosts.isEmpty {
                ContentUnavailableView("No computers yet", systemImage: "desktopcomputer",
                    description: Text("Usage comes from the computers that run your agents. Open Harness on one and sign in."))
            } else {
                if hosts.count > 1 {
                    Section {
                        Picker("Computer", selection: Binding(
                            get: { deviceId ?? "" },
                            set: { selectedDeviceId = $0 }
                        )) {
                            ForEach(hosts) { host in
                                Text(model.deviceOnline(host.id) ? host.name : "\(host.name) (offline)")
                                    .tag(host.id)
                            }
                        }
                        .accessibilityIdentifier("usage-device")
                    }
                }
                content
            }
        }
        .refreshable { await reload(force: true) }
        .task(id: deviceId) { await reload(force: false) }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(.secondary)
                Button("Try again") { Task { await reload(force: true) } }
            }
        case .loaded(let codegraff, let accounts):
            codegraffSection(codegraff)
            agentSections(accounts)
        }
    }

    @ViewBuilder
    private func codegraffSection(_ usage: CodegraffUsage?) -> some View {
        Section {
            if let usage {
                LabeledContent("Account", value: usage.email)
                LabeledContent("Plan", value: usage.tier.capitalized)
                LabeledContent("Credits available", value: formatMicroUSD(usage.creditsMicroUSD))
                LabeledContent("Spent in 30 days", value: formatMicroUSD(usage.spend30dMicroUSD))
                LabeledContent("Requests in 30 days", value: usage.requests30d.formatted())
                if let budget = usage.budgetWindow {
                    UsageMeterRow(window: budget, now: now,
                                  detail: "\(formatMicroUSD(usage.keySpendMonthlyMicroUSD)) of \(formatMicroUSD(usage.keyBudgetMonthlyMicroUSD ?? 0))")
                }
            } else {
                Text("This computer isn't signed in to CodeGraff.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("CodeGraff")
        }
        .accessibilityIdentifier("usage-codegraff")
    }

    @ViewBuilder
    private func agentSections(_ accounts: [AgentAccount]) -> some View {
        let shown = accounts.filter { $0.active || !$0.usageWindows.isEmpty }
        if shown.isEmpty {
            Section("Agent plans") {
                Text("No agent sign-ins with plan limits on this computer.")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(shown) { account in
            Section {
                if account.usageWindows.isEmpty {
                    Text("No plan limits reported.").foregroundStyle(.secondary)
                }
                ForEach(account.usageWindows) { window in
                    UsageMeterRow(window: window, now: now)
                }
            } header: {
                Text(HarnessCatalog.label(for: account.harness))
            } footer: {
                Text([account.title, account.planLabel, account.active ? "In use" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    private func reload(force: Bool) async {
        guard let deviceId else { return }
        if case .loaded = state, !force {} else { state = .loading }
        // The two answers are independent; one failing (a CLI that can't
        // report, a signed-out gateway) shouldn't blank the other.
        async let codegraff = capture { try await model.codegraffUsage(deviceId: deviceId) }
        async let accounts = capture { try await model.agentAccounts(deviceId: deviceId, forceUsage: force) }
        let (usage, snapshot) = await (codegraff, accounts)
        guard self.deviceId == deviceId else { return }
        now = Date()
        switch (usage, snapshot) {
        case (.failure(let error), .failure):
            state = .failed("Couldn't reach \(model.deviceName(deviceId)): \(describeTransportError(error))")
        default:
            state = .loaded(codegraff: (try? usage.get()) ?? nil,
                            accounts: (try? snapshot.get())?.accounts ?? [])
        }
    }

    private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

private struct UsageMeterRow: View {
    let window: UsageWindow
    let now: Date
    var detail: String? = nil

    private var tint: Color {
        switch window.level {
        case .normal: return Theme.accent
        case .warn: return Theme.warning
        case .critical: return Theme.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label)
                Spacer()
                Text("\(Int((window.usedFraction * 100).rounded()))% used")
                    .monospacedDigit()
                    .foregroundStyle(window.level == .normal ? .secondary : tint)
            }
            ProgressView(value: window.usedFraction)
                .tint(tint)
            let notes = [detail, formatResetsIn(window.resetsAt, now: now)].compactMap { $0 }
            if !notes.isEmpty {
                Text(notes.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
