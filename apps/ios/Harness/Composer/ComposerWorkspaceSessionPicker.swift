import SwiftUI

/// Search all sessions, not just the recent sessions in the floating switcher.
struct ComposerWorkspaceSessionPicker: View {
    @Environment(AppModel.self) private var model
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var chats: [Chat] {
        let open = sortActive(model.overviewChats)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return open }
        return open.filter {
            $0.displayTitle.lowercased().contains(needle)
                || ($0.lastMessagePreview ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if chats.isEmpty, model.archivedMatches(in: nil, query: query).isEmpty {
                    Text(query.isEmpty ? "No sessions" : "No matching sessions")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                }
                ForEach(chats) { chat in
                    ChatRow(chat: chat, showLocation: true) { pick(chat.id) }
                }
                ArchivedSection(query: query, path: Binding(get: { [] }, set: { routes in
                    if case .chat(let id)? = routes.last { pick(id) }
                }))
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search sessions")
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
