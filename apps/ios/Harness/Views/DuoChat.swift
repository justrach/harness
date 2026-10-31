// iPhone Duo chat: the pieces the folded (and unfolded) session uses on a foldable.
//
// Tool groups read as one line of chips, edits get a diff summary card, and a running turn is one small
// glass pill above the composer (status and elapsed; Stop behind a tap or a press and hold, never next to
// Send). The type scale here is two sizes (15 and 13) plus mono, in two weights (regular and medium).
//
// Only on a device that has reported a fold or its inner display (`DuoChat.foldableKey`); every other
// iPhone keeps the chat exactly as it was.

import SwiftUI

enum DuoChat {
    /// UserDefaults: this device has reported a fold or its inner display, so it is an iPhone Duo.
    static let foldableKey = "foldableDevice"

    /// A window that only an iPhone Duo has: an active fold, or a phone window regular both ways (the inner
    /// display lying flat).
    static func isFoldableWindow(phone: Bool, regularWidth: Bool, regularHeight: Bool, fold: FoldSplit) -> Bool {
        fold != .none || (phone && regularWidth && regularHeight)
    }

    /// The inner display lying flat: a phone window regular both ways with no fold. The session splits at
    /// the window's middle (where the fold is), chat on the left and Inspect on the right.
    static func isFlat(phone: Bool, regularWidth: Bool, regularHeight: Bool, fold: FoldSplit) -> Bool {
        fold == .none && phone && regularWidth && regularHeight
    }

    /// Rig (DEBUG): `-demo-duo-flat` lays a session out as on a Duo lying flat, chat and Inspect, on any wide
    /// simulator. The Duo simulator has no command to unfold, so its inner display can't be captured from a
    /// script.
    #if DEBUG
    static let demoFlat = ProcessInfo.processInfo.arguments.contains("-demo-duo-flat")
    #else
    static let demoFlat = false
    #endif
}

extension EnvironmentValues {
    /// The session is on an iPhone Duo: chips, diff card and the status pill (DuoChat).
    @Entry var duoChat: Bool = false
}

/// The folded chat's type scale: two sizes plus mono, two weights.
enum DuoType {
    static let body: CGFloat = 15
    static let small: CGFloat = 13
    static func sans(small: Bool = false, medium: Bool = false) -> Font {
        Theme.sans(small ? Self.small : body, weight: medium ? .medium : .regular)
    }
    static var mono: Font { Theme.mono(small) }
}

// MARK: - Tool chips

/// One tool group as a line of chips: what ran, by kind, and what failed.
enum ToolChips {
    struct Chip: Equatable, Identifiable {
        var id: String { symbol }
        let symbol: String
        let count: Int
        let label: String
        var failed = false
    }

    static func chips(_ tools: [ToolItem]) -> [Chip] {
        func count(_ tags: Set<String>) -> Int { tools.filter { tags.contains($0.call.tag) }.count }
        let runs = count(["exec"])
        let edits = count(["editFile", "writeFile", "applyPatch"])
        let reads = count(["readFile"])
        let searches = count(["search", "glob", "webSearch", "webFetch"])
        let other = tools.count - runs - edits - reads - searches
        let failed = tools.filter(\.isError).count
        var chips: [Chip] = []
        if runs > 0 { chips.append(Chip(symbol: "terminal", count: runs, label: runs == 1 ? "1 run" : "\(runs) runs")) }
        if edits > 0 { chips.append(Chip(symbol: "pencil", count: edits, label: edits == 1 ? "1 edit" : "\(edits) edits")) }
        if reads > 0 { chips.append(Chip(symbol: "doc.text", count: reads, label: reads == 1 ? "1 read" : "\(reads) reads")) }
        if searches > 0 {
            chips.append(Chip(symbol: "magnifyingglass", count: searches,
                              label: searches == 1 ? "1 search" : "\(searches) searches"))
        }
        if other > 0 { chips.append(Chip(symbol: "square.grid.2x2", count: other, label: other == 1 ? "1 tool" : "\(other) tools")) }
        if failed > 0 {
            chips.append(Chip(symbol: "exclamationmark.triangle", count: failed, label: "\(failed) failed", failed: true))
        }
        return chips
    }
}

/// The tool group's header on a Duo: the disclosure chevron and one line of chips. Short of room, the chips
/// drop their words and keep the symbol and count, so the line never wraps.
struct ToolChipStrip: View {
    let tools: [ToolItem]
    let open: Bool

    var body: some View {
        let chips = ToolChips.chips(tools)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 26)
            ViewThatFits(in: .horizontal) {
                row(chips, words: true)
                row(chips, words: false)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toolGroupSummary(tools))
    }

    private func row(_ chips: [ToolChips.Chip], words: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                HStack(spacing: 4) {
                    Image(systemName: chip.symbol).font(.system(size: 11, weight: .medium))
                    Text(words ? chip.label : "\(chip.count)")
                        .font(DuoType.sans(small: true))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 24)
                .foregroundStyle(chip.failed ? Theme.danger : Theme.textMuted)
                .background(chip.failed ? Theme.danger.opacity(0.12) : Theme.text.opacity(0.06), in: Capsule())
            }
        }
    }
}

// MARK: - Diff summary

/// What a tool group changed: the files it edited and, when the host sent them, the line counts.
/// The session doc keeps only each edit's path (the render-parts policy strips old and new text), so live
/// groups show the files alone; `additions` and `deletions` fields fill in the counts when present.
struct DiffSummary: Equatable {
    var files: [String]
    var additions: Int?
    var deletions: Int?

    static let editTags: Set<String> = ["editFile", "writeFile", "applyPatch"]

    static func from(_ tools: [ToolItem]) -> DiffSummary? {
        var files: [String] = []
        var additions: Int?
        var deletions: Int?
        for tool in tools where editTags.contains(tool.call.tag) && !tool.isError {
            if let path = tool.call.string("path"), !path.isEmpty, !files.contains(path) { files.append(path) }
            if let added = int(tool.call.fields["additions"]) { additions = (additions ?? 0) + added }
            if let removed = int(tool.call.fields["deletions"]) { deletions = (deletions ?? 0) + removed }
        }
        guard !files.isEmpty else { return nil }
        return DiffSummary(files: files, additions: additions, deletions: deletions)
    }

    private static func int(_ value: AnyHashable?) -> Int? {
        if let value = value as? Int64 { return Int(value) }
        return value as? Int
    }

    var title: String { files.count == 1 ? "1 file changed" : "\(files.count) files changed" }

    /// The files by name, for the card's second line.
    var names: String {
        files.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", ")
    }
}

extension EnvironmentValues {
    /// Open a tool group's changes in the Inspect pane; nil where there is no pane.
    @Entry var inspectDiff: ((DiffSummary) -> Void)? = nil
}

/// "+N -M, K files" under a tool group that edited files.
struct DiffSummaryCard: View {
    let summary: DiffSummary
    var onTap: (() -> Void)?

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plusminus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(DuoType.sans(medium: true))
                        .foregroundStyle(Theme.text)
                    Text(summary.names)
                        .font(DuoType.sans(small: true))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let additions = summary.additions {
                    Text("+\(additions)").font(DuoType.mono).foregroundStyle(Theme.statusCompleted)
                }
                if let deletions = summary.deletions {
                    Text("-\(deletions)").font(DuoType.mono).foregroundStyle(Theme.danger)
                }
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(Theme.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diff-summary-card")
    }
}

// MARK: - Status pill

/// A running turn on a Duo: one small glass pill above the composer, in place of the status strip. Tap it
/// for Stop; press and hold it to stop at once. Stop never sits next to Send.
struct RunStatusPill: View {
    let chatId: String
    let startedAtMs: Int64
    let onStop: () -> Void
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let elapsed = max(0, (nowMs() - startedAtMs) / 1000)
            HStack(spacing: 8) {
                WorkingSpinner()
                Text("\(Motion.flavourWord(seed: Motion.flavourSeed(chatId), elapsedSecs: elapsed))…")
                    .font(DuoType.sans(small: true))
                    .foregroundStyle(Theme.textMuted)
                Text(Motion.formatElapsed(elapsed))
                    .font(DuoType.mono)
                    .foregroundStyle(Theme.textFaint)
                    .monospacedDigit()
                if expanded {
                    Rectangle().fill(Theme.border).frame(width: 0.5, height: 16)
                    Button {
                        stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(DuoType.sans(small: true, medium: true))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("pill-stop")
                    .transition(.opacity)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
        }
        .fixedSize()
        .onTapGesture { withAnimation(reduceMotion ? nil : Motion.resize) { expanded.toggle() } }
        .onLongPressGesture(minimumDuration: 0.6) { stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Working")
        .accessibilityHint("Tap for Stop, or press and hold to stop")
        .accessibilityAction(named: "Stop") { stop() }
        .accessibilityIdentifier("run-status-pill")
    }

    private func stop() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onStop()
        withAnimation(reduceMotion ? nil : Motion.resize) { expanded = false }
    }
}

// MARK: - Edge swipe

/// Swipe in from the leading edge to go back. The session's pager owns horizontal swipes elsewhere.
struct EdgeSwipeBack: View {
    let back: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 18)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        if value.translation.width > 70, abs(value.translation.height) < 80 { back() }
                    }
            )
            .accessibilityHidden(true)
    }
}
