// Settings > Simulators. The iOS Simulators on one of your Macs: open one to
// watch it live and use it from here (SimulatorScreenView). The Mac streams
// through a helper it installs only when you set it up here. Calls go to the
// Mac's engine over its relay, like terminals, so only your own devices reach it.

import SwiftUI

struct SimulatorsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDeviceId: String?
    @State private var state: LoadState = .idle
    @State private var loadedDeviceId: String?
    @State private var busy: String?
    @State private var actionError: String?
    @State private var open: OpenSimulator?

    enum LoadState {
        case idle
        case loading
        case loaded(SimulatorList)
        case failed(String)
    }

    struct OpenSimulator: Identifiable {
        var deviceId: String
        var simulator: SimulatorDevice
        var id: String { simulator.id }
    }

    /// Macs (only they run iOS Simulators), online ones first.
    private var hosts: [DeviceRow] { model.simulatorMacs }

    private var deviceId: String? {
        if let selectedDeviceId, hosts.contains(where: { $0.id == selectedDeviceId }) {
            return selectedDeviceId
        }
        return hosts.first?.id
    }

    var body: some View {
        List {
            if hosts.isEmpty {
                ContentUnavailableView("No Mac yet", systemImage: "desktopcomputer",
                    description: Text("iOS Simulators run on a Mac. Open Harness on it and sign in."))
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
                        .accessibilityIdentifier("simulators-device")
                    }
                    .harnessListRow()
                }
                content
            }
        }
        .harnessGroupedList()
        .refreshable { await reload() }
        .task(id: deviceId) { await reload() }
        .navigationTitle("Simulators")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't do that", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .fullScreenCover(item: $open) { target in
            SimulatorScreenView(deviceId: target.deviceId, simulator: target.simulator)
        }
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
                Text(message).foregroundStyle(.secondary)
            }
            .harnessListRow()
        case .loaded(let list):
            if !list.supported {
                Section {
                    Text(list.reason ?? "This computer can't run iOS Simulators.")
                        .foregroundStyle(.secondary)
                }
                .harnessListRow()
            } else if !list.setUp {
                setUpSection
            } else if list.devices.isEmpty {
                Section {
                    Text("No iOS Simulators on \(computerName). Add one in Xcode.")
                        .foregroundStyle(.secondary)
                }
                .harnessListRow()
            } else {
                deviceSections(list.devices)
            }
        }
    }

    private var computerName: String {
        deviceId.map { model.deviceName($0) } ?? "this computer"
    }

    private var setUpSection: some View {
        Section {
            Button {
                Task { await setUp() }
            } label: {
                HStack {
                    Text("Set up on \(computerName)")
                    Spacer()
                    if busy == "setup" { ProgressView() }
                }
            }
            .disabled(busy != nil)
            .accessibilityIdentifier("simulators-set-up")
        } footer: {
            Text("To stream a simulator here, \(computerName) installs a pinned helper with npm (Node.js 20 or newer). It listens only on that Mac, answers only Harness, and stops when nobody is watching. This takes a minute.")
        }
        .harnessListRow()
    }

    @ViewBuilder
    private func deviceSections(_ devices: [SimulatorDevice]) -> some View {
        let booted = devices.filter(\.booted)
        let rest = devices.filter { !$0.booted }
        if !booted.isEmpty {
            Section("Running") {
                ForEach(booted) { row($0) }
            }
            .harnessListRow()
        }
        if !rest.isEmpty {
            Section {
                ForEach(rest) { row($0) }
            } header: {
                Text("Off")
            } footer: {
                Text("Opening one starts it on \(computerName).")
            }
            .harnessListRow()
        }
    }

    private func row(_ simulator: SimulatorDevice) -> some View {
        Button {
            Task { await openSimulator(simulator) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(simulator.name).foregroundStyle(.primary)
                    Text(simulator.runtime).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if busy == simulator.id {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(busy != nil)
        .swipeActions {
            if simulator.booted {
                Button("Shut down", role: .destructive) {
                    Task { await shutDown(simulator) }
                }
            }
        }
        .accessibilityIdentifier("simulator-\(simulator.id)")
    }

    private func reload() async {
        guard let deviceId else { return }
        if case .loaded = state, loadedDeviceId == deviceId {} else { state = .loading }
        do {
            let list = try await model.simulatorHost().listSimulators(deviceId: deviceId)
            guard self.deviceId == deviceId else { return }
            loadedDeviceId = deviceId
            state = .loaded(list)
        } catch {
            guard self.deviceId == deviceId else { return }
            loadedDeviceId = deviceId
            state = .failed(describe(error))
        }
    }

    private func setUp() async {
        guard let deviceId else { return }
        busy = "setup"
        defer { busy = nil }
        do {
            let list = try await model.simulatorHost().setUpSimulators(deviceId: deviceId)
            if self.deviceId == deviceId { state = .loaded(list) }
        } catch {
            actionError = describe(error)
        }
    }

    private func openSimulator(_ simulator: SimulatorDevice) async {
        guard let deviceId else { return }
        if !simulator.booted {
            busy = simulator.id
            defer { busy = nil }
            do {
                try await model.simulatorHost().bootSimulator(deviceId: deviceId, simulatorId: simulator.id)
            } catch {
                actionError = describe(error)
                return
            }
        }
        var running = simulator
        running.booted = true
        open = OpenSimulator(deviceId: deviceId, simulator: running)
        await reload()
    }

    private func shutDown(_ simulator: SimulatorDevice) async {
        guard let deviceId else { return }
        busy = simulator.id
        defer { busy = nil }
        do {
            try await model.simulatorHost().shutdownSimulator(deviceId: deviceId, simulatorId: simulator.id)
        } catch {
            actionError = describe(error)
        }
        await reload()
    }

    private func describe(_ error: Error) -> String {
        SimulatorHosts.failure(error, deviceName: computerName)
    }
}
