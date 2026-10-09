// Settings > Graff compaction. The setting belongs to the computer that runs
// graff (its engine passes it to every graff chat it starts), so this reads
// and writes it on one computer over its relay, the same value the desktop's
// Settings → Agents shows on the Graff row.

import SwiftUI

struct CompactionView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDeviceId: String?
    @State private var state: LoadState = .idle
    /// The computer `state` describes; another one shows a spinner, not a stale value.
    @State private var loadedDeviceId: String?
    @State private var saving = false

    enum LoadState: Equatable {
        case idle
        case loading
        /// nil is graff's default (80%).
        case loaded(Int?)
        case failed(String)
    }

    /// The desktop's choices. nil restores graff's default.
    static let choices: [Int?] = [nil, 50, 60, 70, 75, 85, 90]

    static func label(_ pct: Int?) -> String {
        pct.map { "\($0)%" } ?? "Default (80%)"
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
                    description: Text("Graff runs on your computers. Open Harness on one and sign in."))
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
                        .accessibilityIdentifier("compaction-device")
                    }
                    .harnessListRow()
                }
                content
            }
        }
        .harnessGroupedList()
        .refreshable { await reload() }
        .task(id: deviceId) { await reload() }
        .navigationTitle("Graff compaction")
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
            .harnessListRow()
        case .failed(let message):
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .harnessListRow()
        case .loaded(let pct):
            Section {
                Picker("Compact context at", selection: Binding(
                    get: { pct },
                    set: { choice in Task { await save(choice) } }
                )) {
                    // A value set elsewhere (graff's own /compact-at range is wider) still shows.
                    ForEach(Self.choices.contains(pct) ? Self.choices : Self.choices + [pct], id: \.self) { choice in
                        Text(Self.label(choice)).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(saving)
                .accessibilityIdentifier("compaction-pct")
            } header: {
                Text("Compact context at")
            } footer: {
                Text("Graff compacts a conversation once it fills this much of the model's context window. Lower keeps each request smaller and cheaper; higher keeps more of the conversation word for word. Applies to Graff chats started after the change. To change one chat, type /compact-at 70 in it.")
            }
            .harnessListRow()
        }
    }

    private func reload() async {
        guard let deviceId else { return }
        if case .loaded = state, loadedDeviceId == deviceId {} else { state = .loading }
        let result: Result<Int?, Error>
        do { result = .success(try await model.graffCompactAt(deviceId: deviceId)) } catch { result = .failure(error) }
        guard self.deviceId == deviceId else { return }
        loadedDeviceId = deviceId
        state = loadState(result, deviceId: deviceId)
    }

    private func save(_ pct: Int?) async {
        guard let deviceId, !saving else { return }
        saving = true
        defer { saving = false }
        state = .loaded(pct)
        let result: Result<Int?, Error>
        do { result = .success(try await model.setGraffCompactAt(deviceId: deviceId, pct: pct)) } catch { result = .failure(error) }
        guard self.deviceId == deviceId else { return }
        // The engine answers with the value it kept; a failure says why (pull to retry).
        state = loadState(result, deviceId: deviceId)
    }

    private func loadState(_ result: Result<Int?, Error>, deviceId: String) -> LoadState {
        switch result {
        case .success(let pct):
            return .loaded(pct)
        case .failure(let error):
            let name = model.deviceName(deviceId)
            if case RelayError.rpc(let message) = error, message.contains("unknown method") {
                return .failed("Update Harness on \(name) to change this from your phone.")
            }
            let reason = (error as? RelayError)?.errorDescription ?? describeTransportError(error)
            return .failed("Couldn't reach \(name): \(reason)")
        }
    }
}
