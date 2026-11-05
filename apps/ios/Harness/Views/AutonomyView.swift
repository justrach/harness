// Settings > Autonomy: how much agents on one computer may do without asking.
// The setting belongs to that computer's engine (it stamps every run's
// sandbox and approvals), so this reads and writes it over the computer's
// relay, the same value the desktop's Settings shows. Until someone picks,
// the engine keeps full access, today's behaviour.

import SwiftUI

struct AutonomyView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDeviceId: String?
    @State private var state: LoadState = .idle
    @State private var loadedDeviceId: String?
    @State private var saving = false
    /// That computer's keep-awake setting; nil hides the row (still loading,
    /// an engine without the setting, or one that can't hold it).
    @State private var keepAwake: KeepAwakeSetting?

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Autonomy)
        case failed(String)
    }

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
                    description: Text("Agents run on your computers. Open Harness on one and sign in."))
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
                        .accessibilityIdentifier("autonomy-device")
                    }
                    .harnessListRow()
                }
                content
            }
        }
        .harnessGroupedList()
        .refreshable { await reload() }
        .task(id: deviceId) { await reload() }
        .navigationTitle("Autonomy")
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
        case .loaded(let autonomy):
            Section {
                Picker("Default autonomy", selection: Binding(
                    get: { autonomy },
                    set: { choice in Task { await save(choice) } }
                )) {
                    ForEach(Autonomy.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.label)
                            Text(level.blurb)
                                .font(Theme.sans(12.5))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .tag(level)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(saving)
                .accessibilityIdentifier("autonomy-level")
            } header: {
                Text("Without asking, agents may")
            } footer: {
                Text("Applies to every agent on this computer, starting with each session's next message. Read only and Workspace ask you on this phone before anything outside what they allow. Full access is how Harness has always run.")
            }
            .harnessListRow()
            if let keepAwake, keepAwake.supported {
                Section {
                    Toggle("Keep awake while agents work", isOn: Binding(
                        get: { keepAwake.enabled },
                        set: { on in Task { await saveKeepAwake(on) } }
                    ))
                    .accessibilityIdentifier("keep-awake-toggle")
                } footer: {
                    Text("The computer won't go to sleep while any chat is working, and can sleep again once they're all done. The display can still turn off, and closing a laptop's lid still puts it to sleep.")
                }
                .harnessListRow()
            }
        }
    }

    private func reload() async {
        guard let deviceId else { return }
        if loadedDeviceId != deviceId { keepAwake = nil }
        if case .loaded = state, loadedDeviceId == deviceId {} else { state = .loading }
        let result: Result<AutonomySetting, Error>
        do { result = .success(try await model.autonomy(deviceId: deviceId)) } catch { result = .failure(error) }
        guard self.deviceId == deviceId else { return }
        loadedDeviceId = deviceId
        state = loadState(result, deviceId: deviceId)
        // Older engines don't have the setting; the row just stays hidden.
        let awake = try? await model.keepAwake(deviceId: deviceId)
        guard self.deviceId == deviceId else { return }
        keepAwake = awake
    }

    private func saveKeepAwake(_ enabled: Bool) async {
        guard let deviceId, let previous = keepAwake else { return }
        keepAwake?.enabled = enabled
        let kept = try? await model.setKeepAwake(deviceId: deviceId, enabled: enabled)
        guard self.deviceId == deviceId else { return }
        keepAwake = kept ?? previous
    }

    private func save(_ autonomy: Autonomy) async {
        guard let deviceId, !saving else { return }
        saving = true
        defer { saving = false }
        state = .loaded(autonomy)
        let result: Result<AutonomySetting, Error>
        do { result = .success(try await model.setAutonomy(deviceId: deviceId, autonomy)) } catch { result = .failure(error) }
        guard self.deviceId == deviceId else { return }
        state = loadState(result, deviceId: deviceId)
    }

    private func loadState(_ result: Result<AutonomySetting, Error>, deviceId: String) -> LoadState {
        switch result {
        case .success(let setting):
            return .loaded(setting.autonomy)
        case .failure(let error):
            let name = model.deviceName(deviceId)
            if case RelayError.rpc(let message) = error, message.contains("unknown method") {
                return .failed("Update Harness on \(name) to change this from your phone.")
            }
            let reason = describeUserFacingError(error)
            return .failed("Couldn't reach \(name): \(reason)")
        }
    }
}
