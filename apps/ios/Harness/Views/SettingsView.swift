// Settings — opened from the gear on Home: how the app looks and behaves.
// The account (usage, sign out, deletion) is Profile, behind the person button.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhoneSplit.storageKey) private var phoneSplitRaw = PhoneSplit.off.rawValue
    /// Opens straight onto Crash reports (the `-sheet crashreports` rig).
    @State private var showCrashReports: Bool
    /// The first-run setup, opened again from Agents.
    @State private var replaySetup = false

    init(openCrashReports: Bool = false) {
        _showCrashReports = State(initialValue: openCrashReports)
    }

    /// "Codegraff · System", or the two variant names when light and dark
    /// come from different families.
    private var themeSummary: String {
        let store = ThemeStore.shared
        let family = { (id: String) -> String? in
            guard let familyId = store.catalog.variant(id)?.familyId else { return nil }
            return store.catalog.families.first { $0.id == familyId }?.name
        }
        let light = family(store.selectedId(for: .light))
        let dark = family(store.selectedId(for: .dark))
        let name = light == dark ? (light ?? store.active.name) : store.active.name
        return store.isMatchingDesktop ? "\(name) · Desktop" : "\(name) · \(store.mode.label)"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        LabeledContent("Theme", value: themeSummary)
                    }
                    .accessibilityIdentifier("settings-appearance")
                }
                .harnessListRow()

                Section("Notifications") {
                    NavigationLink {
                        NotificationsView()
                    } label: {
                        Text("Session notifications")
                    }
                    .accessibilityIdentifier("settings-notifications")
                }
                .harnessListRow()

                Section("Agents") {
                    NavigationLink {
                        AutonomyView()
                    } label: {
                        Text("Autonomy")
                    }
                    .accessibilityIdentifier("settings-autonomy")
                    NavigationLink {
                        CompactionView()
                    } label: {
                        Text("Graff compaction")
                    }
                    .accessibilityIdentifier("settings-compaction")
                    Button("Replay setup") { replaySetup = true }
                        .foregroundStyle(Theme.text)
                        .accessibilityIdentifier("settings-replay-setup")
                }
                .harnessListRow()

                // The Codegraff account a computer is signed in with: its cloud
                // sandboxes and GitHub CI runners, as the desktop's Settings shows them.
                Section("Codegraff") {
                    NavigationLink {
                        CloudSandboxesView()
                    } label: {
                        Text("Cloud sandboxes")
                    }
                    .accessibilityIdentifier("settings-cloud-sandboxes")
                    NavigationLink {
                        GithubCIView()
                    } label: {
                        Text("GitHub CI")
                    }
                    .accessibilityIdentifier("settings-github-ci")
                }
                .harnessListRow()

                // A Mac's iOS Simulators, live on this phone. Only Macs run
                // them, so the row is hidden until one of your computers is a Mac.
                if !model.simulatorMacs.isEmpty {
                    Section("Devices") {
                        NavigationLink {
                            SimulatorsView()
                        } label: {
                            Text("Simulators")
                        }
                        .accessibilityIdentifier("settings-simulators")
                    }
                    .harnessListRow()
                }

                // Shown on every device: the choice applies whenever the window is narrow (a phone, iPhone Duo's
                // outer display, a narrow iPad window). Wide windows always show the list beside the session.
                Section {
                    Picker("Split view", selection: $phoneSplitRaw) {
                        ForEach(PhoneSplit.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings-phone-split")
                } header: {
                    Text("Layout")
                } footer: {
                    Text("For narrow windows, such as a phone or iPhone Duo's outer display. Shows the session list and the open session together when there is room. Auto does it side by side whenever the window is wide enough, such as in landscape. Side by side and Stacked pick a shape. Off keeps the single screen. Wide windows always show the list beside the session.")
                }
                .harnessListRow()

                Section("Diagnostics") {
                    NavigationLink {
                        ConnectionView()
                    } label: {
                        LabeledContent("Connection", value: model.connectionReport().registry)
                    }
                    .accessibilityIdentifier("settings-connection")
                    NavigationLink {
                        PerformanceView()
                    } label: {
                        LabeledContent("Performance", value: Perf.shared.startupMs.map { "Started in \($0) ms" } ?? "")
                    }
                    .accessibilityIdentifier("settings-performance")
                    NavigationLink {
                        CrashReportsView()
                    } label: {
                        Text("Crash reports")
                    }
                    .accessibilityIdentifier("settings-crash-reports")
                }
                .harnessListRow()

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link("Privacy policy", destination: Endpoints.privacyURL)
                    Link("Help and feedback", destination: Endpoints.supportURL)
                    Link("Email support", destination: Endpoints.supportEmailURL)
                }
                .harnessListRow()
            }
            .harnessGroupedList()
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showCrashReports) { CrashReportsView() }
            .fullScreenCover(isPresented: $replaySetup) {
                OnboardingView { replaySetup = false }
                    .environment(model)
                    .harnessAppearance()
                    .tint(Theme.text)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .harnessAppearance()
    }
}
