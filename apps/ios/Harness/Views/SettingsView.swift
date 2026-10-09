// Settings — opened from the gear on Home: how the app looks and behaves.
// The account (usage, sign out, deletion) is Profile, behind the person button.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhoneSplit.storageKey) private var phoneSplitRaw = PhoneSplit.off.rawValue

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
                        CompactionView()
                    } label: {
                        Text("Graff compaction")
                    }
                    .accessibilityIdentifier("settings-compaction")
                }
                .harnessListRow()

                // iPad already shows the list beside the open session; a phone can too, when there is room.
                if UIDevice.current.userInterfaceIdiom == .phone {
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
                        Text("Shows the session list and the open session together when there is room. Auto does it side by side whenever the screen is wide enough, such as in landscape. Side by side and Stacked pick a shape. Off keeps the single screen.")
                    }
                    .harnessListRow()
                }

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
