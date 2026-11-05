// iPhone Duo, v3 layouts.
//
// Wide (lying flat): the session list beside the chat, which keeps a reading width. Opening a diff or a tool
// row swaps the list for Inspect, which meets the chat at the fold; closing Inspect brings the list back.
// Upright (half open, the fold across): the chat above the hinge with its composer parked on it, Inspect
// below (the diff and Approve). Typing, the keyboard takes the lower half; a one-line status strip sits
// above the composer.
// Everywhere: the focused composer is one line, with the model chips folded into one token.

import SwiftUI

enum DuoV3 {
    /// The chat's reading width on the wide display, beside the list.
    static let readingWidth: CGFloat = 526
    /// The session list's column on the wide display.
    static let sidebarWidth: CGFloat = 296
}

// MARK: - Composer token

/// The composer's chips as one token: "#77 · GPT-5.6 · High".
enum ComposerToken {
    static func label(pullRequest: UInt64?, model: String, reasoning: String?, options: [String] = []) -> String {
        var parts: [String] = []
        if let pullRequest { parts.append("#\(pullRequest)") }
        if !model.isEmpty { parts.append(model) }
        if let reasoning, !reasoning.isEmpty { parts.append(reasoning) }
        parts.append(contentsOf: options.filter { !$0.isEmpty })
        return parts.joined(separator: " · ")
    }
}

/// Ask for changes (Inspect) puts the cursor in this session's composer.
@MainActor @Observable
final class DuoComposerFocus {
    static let shared = DuoComposerFocus()
    private(set) var ticks: [String: Int] = [:]
    func request(_ chatId: String) { ticks[chatId, default: 0] += 1 }
    func tick(_ chatId: String) -> Int { ticks[chatId] ?? 0 }
}

// MARK: - Diff line numbers

enum DiffNumbers {
    /// The start lines in "@@ -old,count +new,count @@".
    static func starts(_ header: String) -> (old: Int, new: Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ part: Substring) -> Int? { Int(part.dropFirst().split(separator: ",").first ?? "") }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        return (old, new)
    }

    /// Each line's number: the old file's for a removed line, the new file's otherwise.
    static func numbers(_ hunk: DiffHunk) -> [Int?] {
        guard var (old, new) = starts(hunk.header) else { return hunk.lines.map { _ in nil } }
        return hunk.lines.map { line in
            switch line.kind {
            case .removed: defer { old += 1 }; return old
            case .added: defer { new += 1 }; return new
            case .context: defer { old += 1; new += 1 }; return new
            }
        }
    }
}

// MARK: - Approve bar

/// Approve and Ask for changes under Inspect's card. Solid: only the pill and the switcher are glass.
struct InspectActionBar: View {
    let approve: (() -> Void)?
    let askForChanges: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { approve?() } label: {
                Text("Approve")
                    .font(DuoType.sans(medium: true))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.text, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(approve == nil)
            .opacity(approve == nil ? 0.35 : 1)
            .accessibilityIdentifier("inspect-approve")
            .accessibilityHint(approve == nil ? "Nothing is waiting for approval" : "Answers the open question with its first option")
            Button(action: askForChanges) {
                Text("Ask for changes")
                    .font(DuoType.sans(medium: true))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.text.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inspect-ask-changes")
        }
        .padding(12)
    }
}

// MARK: - Inspect card

/// Inspect's switcher over a card (the diff with its file header, the terminal, or the files) and the
/// Approve bar. `title` shows "Inspect" beside the switcher (upright); `close` puts the list back (wide).
struct InspectCard: View {
    let model: InspectModel
    @Bindable var state: InspectState
    var title = false
    var close: (() -> Void)? = nil
    let approve: (() -> Void)?
    let askForChanges: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if title {
                    Text("Inspect").font(Theme.sans(20, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                }
                InspectSwitcher(selection: $state.segment)
                    .frame(maxWidth: title ? 380 : .infinity)
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 36, height: 36)
                            .background(Theme.text.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Inspect")
                    .accessibilityIdentifier("inspect-close")
                }
            }
            VStack(spacing: 0) {
                Group {
                    switch state.segment {
                    case .diff: InspectDiffView(files: model.files, state: state)
                    case .terminal: InspectTerminalView(commands: model.commands, state: state)
                    case .files: InspectFilesView(rows: model.tree, detailed: model.detailed, state: state)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(Theme.border).frame(height: 1)
                InspectActionBar(approve: approve, askForChanges: askForChanges)
            }
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.surface.ignoresSafeArea(.container, edges: .bottom))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspect-pane")
    }
}

// MARK: - Status strip (upright, typing)

/// One line above the composer while the keyboard covers Inspect: the changes so far, what is running, and
/// a way back to the diff.
struct DuoStatusStrip: View {
    let model: InspectModel
    let activity: String?
    let showDiff: () -> Void

    private var changes: String {
        let adds = model.files.compactMap(\.additions).reduce(0, +)
        let dels = model.files.compactMap(\.deletions).reduce(0, +)
        return model.files.isEmpty ? "No changes" : "+\(adds) -\(dels)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Changes").font(DuoType.sans(small: true, medium: true)).foregroundStyle(Theme.text)
            Text(changes).font(DuoType.mono).foregroundStyle(Theme.textMuted)
            if let activity {
                Text("·").foregroundStyle(Theme.textFaint)
                Text(activity).font(DuoType.sans(small: true)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: showDiff) {
                Text("Diff \u{203A}").font(DuoType.sans(small: true, medium: true)).foregroundStyle(Theme.accent)
                    .frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("duo-status-diff")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo-status-strip")
    }

    /// What the strip says is happening: the running command, else the last one.
    static func activity(_ model: InspectModel, running: Bool) -> String? {
        if let live = model.commands.last(where: \.running) { return "$ " + live.command }
        if running { return "Working" }
        return model.commands.last.map { ($0.failed ? "Failed: $ " : "$ ") + $0.command }
    }
}
