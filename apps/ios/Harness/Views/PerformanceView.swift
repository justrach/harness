// Settings > Performance (PerformanceScreen.kt on Android). Shows what the on-device monitor has seen this
// run: startup, main-thread turns, each measured operation against its budget, memory and thermal state.
// Nothing leaves the device; "Copy report" puts numbers on the clipboard so they can be pasted into an issue.

import SwiftUI

struct PerformanceView: View {
    @AppStorage(PerfSharing.key) private var share = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        // Re-read the counters once a second while the page is open.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let perf = Perf.shared
            let turns = perf.turns.snapshot()
            let stats = perf.recorder.stats()
            List {
                Section("Startup") {
                    LabeledContent("First frame", value: perf.startupMs.map { "\($0) ms" } ?? "Not measured this run")
                }
                Section("Main thread") {
                    LabeledContent("Turns", value: "\(turns.turns)")
                    LabeledContent("Slow", value: "\(turns.slow) (\(String(format: "%.1f", turns.slowPercent))%)")
                    LabeledContent("Frozen", value: "\(turns.frozen)")
                    LabeledContent("Median · 95th", value: "\(String(format: "%.1f", turns.p50)) · \(String(format: "%.1f", turns.p95)) ms")
                    LabeledContent("Worst", value: "\(String(format: "%.0f", turns.worst)) ms")
                }
                Section("Operations") {
                    if stats.isEmpty {
                        Text("Nothing measured yet").foregroundStyle(.secondary)
                    }
                    ForEach(stats, id: \.name) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(stat.name)
                                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                                    .foregroundStyle(stat.overBudget > 0 ? Color.red : Color.primary)
                                Spacer()
                                Text("×\(stat.count)").foregroundStyle(.secondary)
                            }
                            Text(timings(stat)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Device") {
                    LabeledContent("Memory", value: "\(perf.memory().footprintMb) MB")
                    LabeledContent("Thermal state", value: Perf.thermalLabel)
                    LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                }
                if PerfSharing.available {
                    Section {
                        Toggle("Share anonymous performance data", isOn: $share)
                            .accessibilityIdentifier("settings-share-performance")
                    } footer: {
                        Text("Sends numbers only: timings, frame counts, memory, thermal state, your device model and the app and OS versions, under a random id that changes on every launch. No chat content, account or device identifiers.")
                    }
                }
                Section {
                    Button("Copy report") { UIPasteboard.general.string = perf.report(version: version) }
                    Button("Reset", role: .destructive) { perf.reset() }
                } header: {
                    Text("Report")
                } footer: {
                    Text(PerfSharing.available
                         ? "Operation columns are median, 95th and worst."
                         : "Measured on this device only and never sent anywhere. Operation columns are median, 95th and worst.")
                }
            }
        }
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func timings(_ stat: SpanStat) -> String {
        let base = String(format: "%.1f / %.1f / %.1f ms", stat.p50, stat.p95, stat.max)
        guard let budget = PerfSpan.budgetsMs[stat.name] else { return base }
        return base + " · budget \(Int(budget)) ms"
    }
}
