// iPhone Duo lying flat: the chat on the left of the fold, Inspect on the right (Diff, Terminal, Files).
//
// What this build has live: every tool call's kind and status, the command an exec ran, the path an edit or
// read touched, and the +/- counts when a host reports them. What it does not have yet: line diffs, command
// output and the project's file tree. The host keeps those in its sidecar payloads (`SidecarPayload` in the
// Rust doc crate), which the doc sync does not carry to iOS. They sit behind `InspectDetailSource`: the live
// source returns nil and the pane says so; the demo source fills them so the layout can be seen.

import SwiftUI

enum InspectSegment: String, CaseIterable, Identifiable {
    case diff = "Diff", terminal = "Terminal", files = "Files"
    var id: String { rawValue }
}

// MARK: - Model

struct DiffLine: Equatable, Identifiable {
    enum Kind: Equatable { case context, added, removed }
    var id: Int
    var kind: Kind
    var text: String
}

struct DiffHunk: Equatable, Identifiable {
    var id: String { header }
    var header: String
    var lines: [DiffLine]
}

struct InspectFile: Equatable, Identifiable {
    var id: String { path }
    var path: String
    var additions: Int?
    var deletions: Int?
    /// nil: the line diff stays on the host (not synced to iOS yet).
    var hunks: [DiffHunk]?
}

struct TerminalCommand: Equatable, Identifiable {
    var id: String
    var command: String
    var failed: Bool
    var running: Bool
    /// nil: the output stays on the host (not synced to iOS yet).
    var output: String?
}

struct FileTreeRow: Equatable, Identifiable {
    enum Mark: Equatable { case edited, read, untouched }
    var id: String { path }
    var path: String
    var name: String
    var depth: Int
    var isDirectory: Bool
    var mark: Mark
}

/// Details the doc sync does not carry yet. Live returns nil for each; demo fills them.
protocol InspectDetailSource {
    func hunks(path: String) -> [DiffHunk]?
    func output(command: String, failed: Bool) -> String?
    /// The project's files beyond the ones the session touched.
    func projectFiles() -> [String]?
}

struct LiveInspectSource: InspectDetailSource {
    func hunks(path: String) -> [DiffHunk]? { nil }
    func output(command: String, failed: Bool) -> String? { nil }
    func projectFiles() -> [String]? { nil }
}

struct InspectModel: Equatable {
    var files: [InspectFile] = []
    var commands: [TerminalCommand] = []
    var tree: [FileTreeRow] = []
    /// True when the line diffs, output and tree came from the host (false on live today).
    var detailed = false

    static let readTags: Set<String> = ["readFile"]

    static func build(_ entries: [MessageEntry], source: InspectDetailSource) -> InspectModel {
        var model = InspectModel()
        var touched: [(String, FileTreeRow.Mark)] = []
        for entry in entries {
            for part in entry.parts {
                guard case .tool(let id, let call, let isError, let resolved) = part else { continue }
                if DiffSummary.editTags.contains(call.tag), let path = call.string("path"), !path.isEmpty {
                    let adds = int(call.fields["additions"]), dels = int(call.fields["deletions"])
                    if let index = model.files.firstIndex(where: { $0.path == path }) {
                        if let adds { model.files[index].additions = (model.files[index].additions ?? 0) + adds }
                        if let dels { model.files[index].deletions = (model.files[index].deletions ?? 0) + dels }
                    } else {
                        model.files.append(InspectFile(path: path, additions: adds, deletions: dels,
                                                       hunks: source.hunks(path: path)))
                    }
                    touched.append((path, .edited))
                } else if readTags.contains(call.tag), let path = call.string("path"), !path.isEmpty {
                    touched.append((path, .read))
                } else if call.tag == "exec", let command = call.string("command") {
                    model.commands.append(TerminalCommand(
                        id: id, command: command, failed: isError, running: !resolved,
                        output: resolved ? source.output(command: command, failed: isError) : nil))
                }
            }
        }
        var marks: [String: FileTreeRow.Mark] = [:]
        for (path, mark) in touched where marks[path] != .edited { marks[path] = mark }
        let project = source.projectFiles()
        for path in project ?? [] where marks[path] == nil { marks[path] = .untouched }
        model.tree = FileTree.rows(marks)
        model.detailed = project != nil
        return model
    }

    private static func int(_ value: AnyHashable?) -> Int? {
        if let value = value as? Int64 { return Int(value) }
        return value as? Int
    }

    var diffSummary: String {
        guard !files.isEmpty else { return "No edits yet" }
        let adds = files.compactMap(\.additions), dels = files.compactMap(\.deletions)
        let base = files.count == 1 ? "1 file" : "\(files.count) files"
        guard !adds.isEmpty || !dels.isEmpty else { return base }
        return "\(base)  +\(adds.reduce(0, +)) -\(dels.reduce(0, +))"
    }
}

enum FileTree {
    typealias Mark = FileTreeRow.Mark

    /// Paths as a tree: directories first at each level, then files, both by name.
    static func rows(_ marks: [String: Mark]) -> [FileTreeRow] {
        final class Node {
            var children: [String: Node] = [:]
            var mark: Mark?
        }
        let root = Node()
        for (path, mark) in marks {
            var node = root
            for part in path.split(separator: "/").map(String.init) {
                if node.children[part] == nil { node.children[part] = Node() }
                node = node.children[part]!
            }
            node.mark = mark
        }
        var rows: [FileTreeRow] = []
        func walk(_ node: Node, prefix: String, depth: Int) {
            let sorted = node.children.sorted { a, b in
                let ad = !a.value.children.isEmpty, bd = !b.value.children.isEmpty
                return ad != bd ? ad : a.key < b.key
            }
            for (name, child) in sorted {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let dir = !child.children.isEmpty
                rows.append(FileTreeRow(path: path, name: name, depth: depth, isDirectory: dir,
                                        mark: child.mark ?? .untouched))
                if dir { walk(child, prefix: path, depth: depth + 1) }
            }
        }
        walk(root, prefix: "", depth: 0)
        return rows
    }
}

/// Inspect's selection, kept per session outside the view so it survives the fold changing the layout.
@MainActor @Observable
final class InspectState {
    var segment: InspectSegment = .diff
    var selectedFile: String?
    /// The terminal's scrollback position (the command block at the top of the view).
    var terminalAnchor: String?

    private static var bySession: [String: InspectState] = [:]

    static func of(_ chatId: String) -> InspectState {
        if let state = bySession[chatId] { return state }
        let state = InspectState()
        bySession[chatId] = state
        return state
    }

    func show(_ tool: ToolItem) {
        switch tool.call.tag {
        case "exec": segment = .terminal
        case let tag where DiffSummary.editTags.contains(tag):
            segment = .diff
            selectedFile = tool.call.string("path")
        case let tag where InspectModel.readTags.contains(tag):
            segment = .files
            selectedFile = tool.call.string("path")
        default: break
        }
    }
}

extension EnvironmentValues {
    /// The session lies flat on an iPhone Duo: chat left of the fold, Inspect right.
    @Entry var duoFlat: Bool = false
    /// Tapping a tool row fills Inspect (flat Duo only).
    @Entry var inspectTool: ((ToolItem) -> Void)? = nil
}

// MARK: - Views

/// Diff, Terminal, Files. With the pill, the one glass control in the flat chat.
struct InspectSwitcher: View {
    @Binding var selection: InspectSegment

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectSegment.allCases) { segment in
                Button { selection = segment } label: {
                    Text(segment.rawValue)
                        .font(DuoType.sans(small: true, medium: true))
                        .foregroundStyle(selection == segment ? Theme.text : Theme.textMuted)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(selection == segment ? Theme.text.opacity(0.08) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspect-\(segment.rawValue.lowercased())")
                .accessibilityAddTraits(selection == segment ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

struct InspectPane: View {
    let model: InspectModel
    @Bindable var state: InspectState

    var body: some View {
        VStack(spacing: 0) {
            InspectSwitcher(selection: $state.segment)
                .padding(.vertical, 10)
            Group {
                switch state.segment {
                case .diff: InspectDiffView(files: model.files, state: state)
                case .terminal: InspectTerminalView(commands: model.commands, state: state)
                case .files: InspectFilesView(rows: model.tree, detailed: model.detailed, state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.surface)
        .accessibilityIdentifier("inspect-pane")
    }
}

/// A note where a stubbed detail would go.
private struct HostOnlyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DuoType.sans(small: true))
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
    }
}

struct InspectDiffView: View {
    let files: [InspectFile]
    @Bindable var state: InspectState

    private var selected: InspectFile? {
        files.first { $0.path == state.selectedFile } ?? files.first
    }

    var body: some View {
        if files.isEmpty {
            HostOnlyNote(text: "No edits in this session yet.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files) { file in fileChip(file) }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 8)
                Rectangle().fill(Theme.border).frame(height: 1)
                if let file = selected {
                    if let hunks = file.hunks {
                        // Lines keep their shape: the diff scrolls sideways instead of wrapping.
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(hunks) { hunk in
                                    Text(hunk.header)
                                        .font(DuoType.mono)
                                        .foregroundStyle(Theme.textFaint)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                    ForEach(hunk.lines) { line in diffLine(line) }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("inspect-diff-lines")
                    } else {
                        HostOnlyNote(text: "Line diffs stay on the host for now. iOS shows which files changed\(file.additions == nil ? "" : " and by how much").")
                    }
                }
            }
        }
    }

    private func fileChip(_ file: InspectFile) -> some View {
        let on = file.path == selected?.path
        return Button { state.selectedFile = file.path } label: {
            HStack(spacing: 6) {
                Text((file.path as NSString).lastPathComponent)
                    .font(DuoType.sans(small: true, medium: on))
                    .foregroundStyle(on ? Theme.text : Theme.textMuted)
                if let adds = file.additions { Text("+\(adds)").foregroundStyle(Theme.statusCompleted) }
                if let dels = file.deletions { Text("-\(dels)").foregroundStyle(Theme.danger) }
            }
            .font(DuoType.mono)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? Theme.text.opacity(0.08) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: on ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inspect-file-\((file.path as NSString).lastPathComponent)")
    }

    private func diffLine(_ line: DiffLine) -> some View {
        let sign: String, tint: Color
        switch line.kind {
        case .added: sign = "+"; tint = Theme.statusCompleted
        case .removed: sign = "-"; tint = Theme.danger
        case .context: sign = " "; tint = .clear
        }
        return Text(sign + " " + line.text)
            .font(DuoType.mono)
            .foregroundStyle(line.kind == .context ? Theme.textMuted : Theme.text)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minWidth: 600, alignment: .leading)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12))
    }
}

struct InspectTerminalView: View {
    let commands: [TerminalCommand]
    @Bindable var state: InspectState

    var body: some View {
        if commands.isEmpty {
            HostOnlyNote(text: "No commands in this session yet.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(commands) { command in block(command).id(command.id) }
                }
                .scrollTargetLayout()
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            // The scrollback position lives in InspectState, so a fold that rebuilds the pane keeps it.
            .scrollPosition(id: $state.terminalAnchor, anchor: .top)
            .background(Theme.bg.opacity(0.6))
            .accessibilityIdentifier("inspect-terminal")
        }
    }

    private func block(_ command: TerminalCommand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$").foregroundStyle(Theme.textFaint)
                Text(command.command).foregroundStyle(Theme.text)
                if command.failed {
                    Text("failed").font(DuoType.sans(small: true)).foregroundStyle(Theme.danger)
                } else if command.running {
                    Text("running").font(DuoType.sans(small: true)).foregroundStyle(Theme.textFaint)
                }
            }
            if let output = command.output {
                Text(output).foregroundStyle(Theme.textMuted)
            } else if !command.running {
                Text("Output stays on the host for now.")
                    .font(DuoType.sans(small: true))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .font(DuoType.mono)
        .textSelection(.enabled)
    }
}

struct InspectFilesView: View {
    let rows: [FileTreeRow]
    let detailed: Bool
    @Bindable var state: InspectState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !detailed {
                    HostOnlyNote(text: "The files this session touched. The full project tree stays on the host for now.")
                }
                ForEach(rows) { row in
                    Button {
                        guard !row.isDirectory else { return }
                        state.selectedFile = row.path
                        if row.mark == .edited { state.segment = .diff }
                    } label: { line(row) }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("inspect-files")
    }

    private func line(_ row: FileTreeRow) -> some View {
        let on = row.path == state.selectedFile
        return HStack(spacing: 8) {
            Image(systemName: row.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textFaint)
            Text(row.name)
                .font(row.isDirectory ? DuoType.sans(small: true) : DuoType.mono)
                .foregroundStyle(row.mark == .untouched && !row.isDirectory ? Theme.textMuted : Theme.text)
            Spacer(minLength: 8)
            switch row.mark {
            case .edited: Text("edited").font(DuoType.sans(small: true)).foregroundStyle(Theme.statusWorking)
            case .read: Text("read").font(DuoType.sans(small: true)).foregroundStyle(Theme.textFaint)
            case .untouched: EmptyView()
            }
        }
        .padding(.leading, 12 + CGFloat(row.depth) * 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .background(on ? Theme.text.opacity(0.06) : .clear)
        .contentShape(Rectangle())
    }
}

/// With the keyboard up, Inspect folds to one line above the chat. A tap puts the keyboard away.
struct InspectPeek: View {
    let model: InspectModel
    let state: InspectState
    let open: () -> Void

    private var summary: String {
        switch state.segment {
        case .diff: return model.diffSummary
        case .terminal: return model.commands.last.map { "$ " + $0.command } ?? "No commands yet"
        case .files: return model.tree.filter { !$0.isDirectory }.count == 1 ? "1 file" : "\(model.tree.filter { !$0.isDirectory }.count) files"
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(state.segment.rawValue).font(DuoType.sans(small: true, medium: true)).foregroundStyle(Theme.text)
                Text(summary).font(DuoType.mono).foregroundStyle(Theme.textMuted).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inspect-peek")
        .accessibilityHint("Puts the keyboard away and shows Inspect")
    }
}

/// Demo mode only: the details live data does not have yet, so the pane's layout can be seen and tested.
struct DemoInspectSource: InspectDetailSource {
    func hunks(path: String) -> [DiffHunk]? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let swift = path.hasSuffix(".swift")
        let raw: [(DiffLine.Kind, String)] = swift ? [
            (.context, "struct \(name.capitalized)Row: View {"),
            (.removed, "    let opacity = progress"),
            (.added, "    // Fast attack, slow release: the veil lifts as soon as text lands and settles on the cadence."),
            (.added, "    let opacity = 1 - pow(1 - progress, 1.6)"),
            (.context, "    var body: some View {"),
        ] : [
            (.context, "fn \(name)_header_color(group: &ToolGroup, theme: &Theme) -> Color {"),
            (.removed, "    if group.any_failed() { return theme.danger; }"),
            (.added, "    // The header stays text_muted on failure; only the chip label and the summary segment turn danger."),
            (.added, "    theme.text_muted"),
            (.context, "}"),
        ]
        let lines = raw.enumerated().map { DiffLine(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
        return [DiffHunk(header: "@@ -41,6 +41,7 @@", lines: lines)]
    }

    func output(command: String, failed: Bool) -> String? {
        if command.hasPrefix("cargo test") {
            return failed
                ? "running 3 tests\ntest shell::tool_group::header_keeps_muted_on_failure ... FAILED\n\nfailures:\n    header color was danger, expected text_muted\ntest result: FAILED. 2 passed; 1 failed"
                : "running 3 tests\ntest shell::tool_group::header_keeps_muted_on_failure ... ok\ntest result: ok. 3 passed; 0 failed"
        }
        return failed ? "error: build failed" : "** BUILD SUCCEEDED **"
    }

    func projectFiles() -> [String]? {
        ["crates/ui/src/shell/mod.rs", "crates/ui/src/shell/composer.rs", "crates/ui/src/markdown/mod.rs",
         "Harness/Transcript/TranscriptView.swift", "Cargo.toml"]
    }
}
