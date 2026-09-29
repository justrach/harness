// Settings — opened from the person button on Home. Account actions live here
// rather than in a quick menu: signing out is one tap away, and deleting the
// account sits apart at the bottom behind its own confirmation.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAccount = false

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
                Section("Account") {
                    if model.demo != nil {
                        LabeledContent("Signed in", value: "Demo mode")
                    } else if model.canDeleteAccount {
                        LabeledContent("Signed in with", value: "CodeGraff")
                    }
                    Button("Sign out", role: .destructive) {
                        dismiss()
                        model.signOut()
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        LabeledContent("Theme", value: themeSummary)
                    }
                    .accessibilityIdentifier("settings-appearance")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                }

                if model.canDeleteAccount {
                    Section {
                        Button("Delete account…", role: .destructive) {
                            confirmDeleteAccount = true
                        }
                        .disabled(model.accountDeletionBusy)
                        .accessibilityIdentifier("settings-delete-account")
                    } footer: {
                        Text("Permanently deletes your CodeGraff account and everything Harness keeps for it.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete your account?", isPresented: $confirmDeleteAccount) {
                Button("Delete", role: .destructive) { Task { await model.deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your CodeGraff account and everything Harness keeps for it: chats, sessions, devices, and the agent rooms you made. Your posts in other people's rooms lose their text. This can't be undone.")
            }
            .alert("Account not deleted", isPresented: Binding(
                get: { model.accountDeletionError != nil },
                set: { if !$0 { model.accountDeletionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.accountDeletionError ?? "")
            }
            .overlay {
                if model.accountDeletionBusy {
                    ProgressView("Deleting account…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .interactiveDismissDisabled(model.accountDeletionBusy)
        .harnessAppearance()
    }
}
