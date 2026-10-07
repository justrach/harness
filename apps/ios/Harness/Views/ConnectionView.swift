// Settings > Connection. Why does the phone say a computer is offline? This answers it without a log: is the
// sign-in alive, is the registry socket up, and when did each device last beat. A snapshot, read when the page
// opens and on pull-down or Refresh — it runs no timer, so it costs nothing while you look at it. "Copy report"
// puts the same lines on the clipboard so they can be pasted into an issue.

import SwiftUI

struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var report: ConnectionReport?
    @State private var asOf = Date()

    var body: some View {
        let report = self.report ?? model.connectionReport()
        List {
            Section("Sign-in") {
                LabeledContent("Account", value: report.signIn)
                LabeledContent("Access token", value: report.accessToken(now: asOf))
                LabeledContent("Last refresh", value: report.lastRefresh(now: asOf))
                if model.sessionExpired {
                    Button("Sign in again") { model.signInAgain() }
                        .disabled(model.signInBusy)
                }
            }
            Section("Registry") {
                LabeledContent("Status", value: report.registry)
            }
            Section("Devices") {
                if report.devices.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(Array(report.devices.enumerated()), id: \.offset) { _, device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.isThisPhone ? "\(device.name) (this phone)" : device.name)
                        Text(ConnectionReport.deviceLine(device))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Refresh") { reload() }
                Button("Copy report") {
                    UIPasteboard.general.string = report.text(now: asOf)
                }
            } footer: {
                Text("Nothing here is sent anywhere. It updates when you open it or pull down.")
            }
        }
        .refreshable { reload() }
        .task { reload() }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reload() {
        report = model.connectionReport()
        asOf = Date()
    }
}
