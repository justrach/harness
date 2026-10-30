// Settings → Crash reports: what iOS reported about Harness crashing,
// hanging or overusing the CPU or disk (CrashReports). Nothing leaves the
// iPhone unless it's shared from here.

import SwiftUI

struct CrashReportsView: View {
    @State private var reports: [CrashReports.Report] = []
    @State private var confirmDelete = false

    var body: some View {
        List {
            if reports.isEmpty {
                Section {
                    Text("No reports yet.")
                        .foregroundStyle(Theme.textMuted)
                } footer: {
                    Text(footer)
                }
                .harnessListRow()
            } else {
                Section {
                    ForEach(reports) { report in
                        ShareLink(item: report.file) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(report.summary.headline)
                                    .font(Theme.sans(15, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(2)
                                Text(detail(report))
                                    .font(Theme.sans(12))
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .accessibilityIdentifier("crash-report-row")
                    }
                } footer: {
                    Text(footer)
                }
                .harnessListRow()
            }
        }
        .navigationTitle("Crash reports")
        .toolbar {
            if !reports.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(items: reports.map(\.file)) {
                        Label("Share all", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Delete all", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .confirmationDialog("Delete every crash report on this iPhone?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                CrashReports.shared.deleteAll()
                reports = []
            }
        }
        .task { reports = CrashReports.shared.reports() }
    }

    private var footer: String {
        "iOS reports a crash, a hang or heavy CPU or disk use to Harness on a later launch, usually the next one. Reports stay on this iPhone; tap one to share it. They hold code addresses, the build, the device model and the iOS version, never chat content."
    }

    private func detail(_ report: CrashReports.Report) -> String {
        let s = report.summary
        var parts: [String] = []
        if let build = s.build { parts.append("Build \(build)") }
        let counts = [(s.crashes, "crash", "crashes"), (s.hangs, "hang", "hangs"), (s.cpu, "CPU", "CPU"),
                      (s.diskWrites, "disk", "disk"), (s.launches, "launch", "launches")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        parts.append(contentsOf: counts)
        parts.append(report.receivedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
