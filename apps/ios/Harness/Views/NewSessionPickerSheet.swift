// "+" on Home: where the new session goes. A menu can't be searched, and
// with many projects the right one meant scrolling the whole list, so this is
// a sheet with the search field always showing. It reports the choice and
// Home acts on it once the sheet has gone (a sheet presented while another is
// still dismissing never appears).

import SwiftUI

enum NewSessionTarget: Equatable {
    case space(String)
    case projectless
    case newSpace
}

struct NewSessionPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The project Home is scoped to, listed first.
    var selectedSpaceId: String? = nil
    let onChoose: (NewSessionTarget) -> Void

    @State private var query = ""

    private var spaces: [Space] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching = model.spaces.filter { space in
            needle.isEmpty
                || space.displayName.localizedCaseInsensitiveContains(needle)
                || space.path.localizedCaseInsensitiveContains(needle)
                || model.deviceName(space.deviceId).localizedCaseInsensitiveContains(needle)
        }
        guard let selectedSpaceId,
              let ix = matching.firstIndex(where: { $0.id == selectedSpaceId }) else { return matching }
        var ordered = matching
        ordered.insert(ordered.remove(at: ix), at: 0)
        return ordered
    }

    var body: some View {
        NavigationStack {
            List {
                if !model.spaces.isEmpty {
                    Section {
                        if spaces.isEmpty {
                            Text("No projects match \u{201C}\(query)\u{201D}")
                                .foregroundStyle(Theme.textMuted)
                        }
                        ForEach(spaces) { space in
                            Button {
                                choose(.space(space.id))
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(space.displayName)
                                            .foregroundStyle(Theme.text)
                                        Text(deviceTag(space))
                                            .font(Theme.sans(12))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                    Spacer()
                                    if space.id == selectedSpaceId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("new-session-space-\(space.id)")
                        }
                    }
                    .harnessListRow()
                }
                Section {
                    Button {
                        choose(.projectless)
                    } label: {
                        Label("Session without a project…", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("new-projectless-session")
                    Button {
                        choose(.newSpace)
                    } label: {
                        Label("New space…", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("new-space")
                }
                .harnessListRow()
            }
            .harnessGroupedList()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .harnessAppearance()
    }

    private func choose(_ target: NewSessionTarget) {
        onChoose(target)
        dismiss()
    }

    private func deviceTag(_ space: Space) -> String {
        let name = model.deviceName(space.deviceId)
        // "offline" only on positive evidence; a host that is merely unconfirmed is not called gone.
        return model.hostStatus(space.deviceId) == .offline ? "@ \(name) · offline" : "@ \(name)"
    }
}
