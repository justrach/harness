// Profile — opened from the person button on Home. The account lives here,
// apart from Settings (the gear): testers opened the person button looking
// for their account and found app preferences instead. Signing out is one tap
// away; deleting the account sits apart at the bottom behind its own
// confirmation.

import SwiftUI

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAccount = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if model.demo != nil {
                        LabeledContent("Signed in", value: "Demo mode")
                    } else if model.canDeleteAccount {
                        LabeledContent("Signed in with", value: "CodeGraff")
                    }
                    NavigationLink {
                        UsageView()
                    } label: {
                        Text("Usage")
                    }
                    .accessibilityIdentifier("profile-usage")
                    Button("Sign out", role: .destructive) {
                        dismiss()
                        model.signOut()
                    }
                    .accessibilityIdentifier("profile-sign-out")
                }
                .harnessListRow()

                if model.canDeleteAccount {
                    Section {
                        Button("Delete account…", role: .destructive) {
                            confirmDeleteAccount = true
                        }
                        .disabled(model.accountDeletionBusy)
                        .accessibilityIdentifier("profile-delete-account")
                    } footer: {
                        Text("Permanently deletes your CodeGraff account and everything Harness keeps for it.")
                    }
                    .harnessListRow()
                }
            }
            .harnessGroupedList()
            .navigationTitle("Profile")
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
