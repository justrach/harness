// Settings → Notifications: whether this phone gets session notifications,
// and which of the desktop's three kinds. The edge sends them; the choices
// travel with this phone's registration (PushNotifications).

import SwiftUI
import UserNotifications

struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = PushNotifications.shared.enabled
    @State private var kinds: [PushNotifications.Kind: Bool] = Dictionary(
        uniqueKeysWithValues: PushNotifications.Kind.allCases.map { ($0, PushNotifications.shared.isOn($0)) })
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            Section {
                Toggle("Session notifications", isOn: $enabled)
                    .accessibilityIdentifier("settings-notifications-enabled")
                    .onChange(of: enabled) { _, on in
                        PushNotifications.shared.enabled = on
                        if on { Task { await askIfNeeded() } }
                    }
            } footer: {
                Text(footer)
            }

            if enabled {
                Section("Notify me when") {
                    ForEach(PushNotifications.Kind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { kinds[kind] ?? true },
                            set: { on in
                                kinds[kind] = on
                                PushNotifications.shared.set(kind, on)
                            }))
                        .accessibilityIdentifier("settings-notifications-\(kind.rawValue)")
                    }
                }
            }

            if enabled && status == .denied {
                Section {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await askIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { status = await PushNotifications.shared.authorizationStatus() }
        }
    }

    private var footer: String {
        if model.demo != nil { return "Demo mode sends no notifications." }
        switch status {
        case .denied:
            return "Notifications are turned off for Harness in iOS Settings."
        default:
            return "A run finished, a session waiting on you, or a run failed, from any of your computers. Quiet while Harness is open."
        }
    }

    /// Opening this screen with notifications on is the person asking for them.
    private func askIfNeeded() async {
        status = await PushNotifications.shared.authorizationStatus()
        guard enabled, model.demo == nil, status == .notDetermined else { return }
        _ = await PushNotifications.shared.requestPermission()
        status = await PushNotifications.shared.authorizationStatus()
    }
}
