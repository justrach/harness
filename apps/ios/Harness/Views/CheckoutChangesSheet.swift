// Live checkout changes + inline line/range review comments — iOS's take on
// the desktop Changes pane (engine `GetCheckoutDiff`, rpc.rs) and Zeron's
// line-review UX, restated natively: one sheet (or Inspect segment) with the
// working tree / this turn / this branch, a +/- summary, collapsible file
// cards of syntax-colored monospaced hunks, and tap-a-line (or a range of
// lines) to collect unsent review comments that leave as ONE batched prompt
// naming every `path:startLine-endLine` with its quoted snippet.
//
// The wire shapes are the engine's own (harness-proto CheckoutDiff /
// WorkspaceDirectoryPage, camelCase); the parser and the selection model are
// pure so tests cover them without a host.

import SwiftUI

// MARK: - Wire (engine harness-proto)

/// GetCheckoutDiff's `mode` — which tree the diff is taken against.
enum CheckoutDiffMode: String, CaseIterable, Identifiable {
    /// The working tree vs HEAD (the plain capture).
    case workingTree = "workingTree"
    /// The turn-start tree snapshot vs the current tree.
    case turn = "turn"
    /// The working tree vs merge-base(baseRef, HEAD).
    case branch = "branch"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workingTree: return "Working tree"
        case .turn: return "Turn"
        case .branch: return "Branch"
        }
    }
}

/// harness-proto DiffFileSummary.
struct CheckoutDiffFileSummary: Decodable, Equatable {
    var path: String
    var oldPath: String?
    var status: String
    var additions: Int
    var deletions: Int
    var binary: Bool

    enum CodingKeys: String, CodingKey {
        case path, oldPath, status, additions, deletions, binary
    }

    init(path: String, oldPath: String? = nil, status: String,
         additions: Int, deletions: Int, binary: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status = try c.decode(String.self, forKey: .status)
        additions = try c.decode(Int.self, forKey: .additions)
        deletions = try c.decode(Int.self, forKey: .deletions)
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
    }
}

/// harness-proto CheckoutDiff — the host's answer to GetCheckoutDiff.
struct CheckoutDiffSnapshot: Decodable, Equatable {
    var checkoutId: String
    var deviceId: String
    var cwd: String
    var patch: String
    var files: [CheckoutDiffFileSummary]
    var additions: Int
    var deletions: Int
    var truncated: Bool
    var checksum: String
    var updatedAt: String

    /// The patch as parsed files (hunks, line numbers, per-file counts);
    /// falls back to the summary rows when the patch itself is empty
    /// (truncated or binary-only checkouts).
    var parsedFiles: [InspectFile] { UnifiedDiffParser.parse(patch, summaries: files) }
}

/// One WorkspaceDirectoryPage entry (harness-proto WorkspaceEntry).
struct WorkspaceDirectoryEntry: Decodable, Equatable {
    var path: String
    var name: String
    var kind: String
}

/// A page of the host's ListWorkspaceDirectory answer.
struct WorkspaceDirectoryPage: Decodable, Equatable {
    var directory: String
    var entries: [WorkspaceDirectoryEntry]
    var nextCursor: String?
    var truncated: Bool
}

// MARK: - Unified diff parser (pure)

/// Parses a git unified diff patch into `InspectFile`s: `diff --git` file
/// boundaries, rename/new-file/deleted-file headers, per-file `+/-` counts,
/// `@@ -old[,n] +new[,n] @@` hunk headers with their old/new start lines, and
/// every `+`/`-`/context row carrying its old/new line number (nil for the
/// side it doesn't exist on). Pure, so the parser is testable without a host.
enum UnifiedDiffParser {
    static func parse(_ patch: String) -> [InspectFile] {
        parse(patch, summaries: [])
    }

    /// `summaries` (the host's DiffFileSummary rows) fill counts and paths the
    /// patch itself doesn't carry — a truncated or binary-only patch keeps its
    /// file list this way.
    static func parse(_ patch: String, summaries: [CheckoutDiffFileSummary]) -> [InspectFile] {
        var files: [InspectFile] = []
        var current: InspectFile?
        var hunks: [DiffHunk] = []
        var lines: [DiffLine] = []
        var header = ""
        var oldNumber = 0
        var newNumber = 0

        func closeHunk() {
            guard !lines.isEmpty || !header.isEmpty else { return }
            hunks.append(DiffHunk(header: header, lines: lines))
            header = ""
            lines = []
        }
        func closeFile() {
            closeHunk()
            guard var file = current else { return }
            if file.hunks == nil { file.hunks = hunks }
            if file.additions == nil { file.additions = hunks.flatMap(\.lines).filter { $0.kind == .added }.count }
            if file.deletions == nil { file.deletions = hunks.flatMap(\.lines).filter { $0.kind == .removed }.count }
            files.append(file)
            current = nil
            hunks = []
        }

        var rawLines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        if patch.hasSuffix("\n"), rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }
        for rawLine in rawLines {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                closeFile()
                let path = filePath(fromGitLine: line) ?? ""
                current = InspectFile(path: path, additions: nil, deletions: nil, hunks: nil)
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                // The b/ side is the file's own name; rename targets keep it.
                if line.hasPrefix("+++ "), let target = quotedPath(in: line.dropFirst(4)),
                   target != "/dev/null" {
                    current?.path = target
                }
                continue
            }
            if line.hasPrefix("@@") {
                closeHunk()
                header = line
                if let starts = DiffNumbers.starts(line) {
                    oldNumber = starts.old
                    newNumber = starts.new
                } else {
                    oldNumber = 0
                    newNumber = 0
                }
                continue
            }
            guard !header.isEmpty else {
                // File metadata between the diff header and the first hunk
                // (new file mode, rename from/to, index, Binary files differ).
                if line.hasPrefix("rename to "), !line.isEmpty {
                    current?.path = String(line.dropFirst("rename to ".count))
                }
                continue
            }
            let kind: DiffLine.Kind
            var old: Int?
            var new: Int?
            if line.hasPrefix("+") {
                kind = .added
                new = newNumber
                newNumber += 1
            } else if line.hasPrefix("-") {
                kind = .removed
                old = oldNumber
                oldNumber += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                kind = .context
                old = oldNumber
                new = newNumber
                oldNumber += 1
                newNumber += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — metadata, not a row.
                continue
            } else {
                continue
            }
            let text = line.isEmpty ? "" : String(line.dropFirst())
            lines.append(DiffLine(id: lines.count, kind: kind, text: text,
                                  oldNumber: old, newNumber: new))
        }
        closeFile()

        // A patch the cap cut short (or a binary-only change): keep the host's
        // summary rows so the file list survives.
        if files.isEmpty, !summaries.isEmpty {
            files = summaries.map {
                InspectFile(path: $0.path, additions: $0.binary ? nil : $0.additions,
                            deletions: $0.binary ? nil : $0.deletions, hunks: [])
            }
        }
        return files
    }

    /// `diff --git a/x b/x` → `x`; quoted paths ("a/my file.txt") keep their
    /// spaces. nil when the line doesn't carry both sides.
    private static func filePath(fromGitLine line: String) -> String? {
        let rest = line.dropFirst("diff --git ".count)
        guard let split = splitGitSides(rest) else { return nil }
        return bPath(split.b) ?? split.a
    }

    /// The two space-separated sides of a `diff --git` line, honoring quotes.
    private static func splitGitSides(_ text: Substring) -> (a: String, b: String)? {
        var sides: [String] = []
        var current = ""
        var quoted = false
        for char in text {
            if char == "\"" { quoted.toggle(); current.append(char) }
            else if char == " " && !quoted {
                if !current.isEmpty { sides.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { sides.append(current) }
        guard sides.count == 2 else { return nil }
        return (sides[0], sides[1])
    }

    /// `a/path` / `b/path` / quoted `"b/my path"` → `path`; `/dev/null` → nil.
    private static func bPath(_ side: String) -> String? {
        var value = side
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard value != "/dev/null" else { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
        return value
    }

    /// The path in a `--- a/x` / `+++ b/x` header line (after the prefix).
    private static func quotedPath(in text: Substring) -> String? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard value != "/dev/null" else { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") { return String(value.dropFirst(2)) }
        return value
    }
}

// MARK: - Review selection (pure)

/// Which lines of one file a review comment covers: one line, or a contiguous
/// range within a single file. Line numbers are the NEW file's (a removed-only
/// range falls back to the old file's numbers, the same convention the diff
/// renders).
struct DiffLineSelection: Equatable {
    var path: String
    var startLine: Int
    var endLine: Int

    /// A single-line selection.
    static func line(_ number: Int, in path: String) -> DiffLineSelection {
        DiffLineSelection(path: path, startLine: number, endLine: number)
    }

    var isRange: Bool { startLine != endLine }

    var label: String {
        isRange ? "\(path):\(startLine)-\(endLine)" : "\(path):\(startLine)"
    }

    /// The range's bounds in display order.
    var bounds: ClosedRange<Int> { min(startLine, endLine)...max(startLine, endLine) }

    /// Expand or trim the selection to include `number` in the same file.
    /// A number outside the current bounds moves the nearest edge (start
    /// below the range, end above it) — never jumps the whole selection —
    /// and a number in a different file starts a fresh single-line selection
    /// there. Contiguity within one file is the invariant.
    func including(_ number: Int, in path: String) -> DiffLineSelection {
        guard path == self.path else { return .line(number, in: path) }
        let low = min(startLine, endLine), high = max(startLine, endLine)
        guard number < low || number > high else { return self }
        let nextLow = min(low, number), nextHigh = max(high, number)
        return DiffLineSelection(path: path, startLine: nextLow, endLine: nextHigh)
    }

    /// Trim one line off an edge: the number leaving the range drops the
    /// nearest edge and keeps the rest; the number inside (or a different
    /// file) changes nothing.
    func excluding(_ number: Int, in path: String) -> DiffLineSelection? {
        guard path == self.path, bounds.contains(number) else { return self }
        let low = min(startLine, endLine), high = max(startLine, endLine)
        if low == high { return nil }  // a single line untapped clears the selection
        if number == low { return DiffLineSelection(path: path, startLine: low + 1, endLine: high) }
        if number == high { return DiffLineSelection(path: path, startLine: low, endLine: high - 1) }
        return self
    }
}

/// One unsent review comment: the lines it covers and the note to send.
struct DiffReviewComment: Identifiable, Equatable {
    var id = UUID().uuidString
    var selection: DiffLineSelection
    var note: String
    /// The quoted diff rows the comment was made on (already `+`/`-`/space
    /// prefixed), captured when the comment was created so a later refresh of
    /// the checkout cannot silently rewrite what is about to be sent.
    var quotedLines: [String]

    init(selection: DiffLineSelection, note: String, quotedLines: [String] = []) {
        self.selection = selection
        self.note = note
        self.quotedLines = quotedLines
    }

    var isValid: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Unsent review comments, per chat, in memory. Edits and removals are plain
/// dictionary writes; nothing persists until the batch is sent.
@MainActor
final class DiffReviewDraftStore: ObservableObject {
    @Published private(set) var commentsByChat: [String: [DiffReviewComment]] = [:]
    private static var sharedStores: [String: DiffReviewDraftStore] = [:]

    static func of(_ chatId: String) -> DiffReviewDraftStore {
        if let store = sharedStores[chatId] { return store }
        let store = DiffReviewDraftStore()
        sharedStores[chatId] = store
        return store
    }

    func comments(for chatId: String) -> [DiffReviewComment] {
        commentsByChat[chatId] ?? []
    }

    func add(_ comment: DiffReviewComment, for chatId: String) {
        commentsByChat[chatId, default: []].append(comment)
    }

    func update(note: String, for id: String, chatId: String) {
        guard let index = commentsByChat[chatId]?.firstIndex(where: { $0.id == id }) else { return }
        commentsByChat[chatId]?[index].note = note
    }

    func remove(id: String, chatId: String) {
        commentsByChat[chatId]?.removeAll { $0.id == id }
    }

    func clear(chatId: String) {
        commentsByChat[chatId] = nil
    }
}

// MARK: - Batched prompt (pure)

/// Formats unsent review comments into one markdown prompt: a header naming
/// the scope, then one block per comment naming `path:startLine-endLine`,
/// quoting the covered diff rows, and the note beneath.
enum DiffReviewPrompt {
    static func prompt(comments: [DiffReviewComment], mode: CheckoutDiffMode) -> String {
        let scope: String
        switch mode {
        case .workingTree: scope = "the working tree"
        case .turn: scope = "this turn's changes"
        case .branch: scope = "the branch's changes"
        }
        let count = comments.count == 1 ? "1 review comment" : "\(comments.count) review comments"
        var out = "Please address \(count) on \(scope):\n"
        for (index, comment) in comments.enumerated() {
            out += "\n\(index + 1). \(comment.selection.label)\n"
            for line in comment.quotedLines where !line.isEmpty {
                out += "   > \(line)\n"
            }
            out += "   \(comment.note.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return out
    }
}

// MARK: - Loaders

extension WorkspaceStore {
    /// GetCheckoutDiff over the chat host's relay (rpc.rs GET_CHECKOUT_DIFF):
    /// `cwd` resolves to the checkout's root on the host, `mode` picks the
    /// base tree (workingTree | turn | branch), and branch needs a `baseRef`.
    func fetchCheckoutDiff(chatId: String, cwd: String, deviceId: String,
                           mode: CheckoutDiffMode, baseRef: String? = nil) async throws -> CheckoutDiffSnapshot {
        var params: [String: Any] = ["cwd": cwd, "mode": mode.rawValue]
        switch mode {
        case .workingTree:
            break
        case .turn:
            params["chatId"] = chatId
        case .branch:
            params["baseRef"] = baseRef ?? "origin/main"
        }
        return try await relay(for: deviceId).call(method: "GetCheckoutDiff", params: params,
                                                   timeoutSeconds: 20)
    }

    /// ListWorkspaceDirectory for the chat's checkout (workspace_files.rs):
    /// one directory per page, cursor-paginated, dotfiles and .git hidden by
    /// the host. Walks subdirectories with a tight bound so Inspect's Files
    /// tree shows real project files without ever pinning the phone.
    func listWorkspaceFiles(chatId: String, deviceId: String,
                            directory: String = "") async throws -> [String] {
        var paths: [String] = []
        var queue: [String] = [directory]
        var visitedDirs = 0
        let maxDirectories = 16
        let maxFiles = 500

        while !queue.isEmpty, visitedDirs < maxDirectories, paths.count < maxFiles {
            let currentDir = queue.removeFirst()
            visitedDirs += 1
            var cursor: String? = nil
            for _ in 0..<20 {
                var params: [String: Any] = ["chatId": chatId, "directory": currentDir]
                if let cursor { params["cursor"] = cursor }
                let page: WorkspaceDirectoryPage
                do {
                    page = try await relay(for: deviceId).call(
                        method: "ListWorkspaceDirectory", params: params)
                } catch {
                    if currentDir == directory && paths.isEmpty { throw error }
                    break
                }
                for entry in page.entries {
                    if entry.kind == "file" {
                        paths.append(entry.path)
                        if paths.count >= maxFiles { break }
                    } else if entry.kind == "directory", visitedDirs + queue.count < maxDirectories {
                        queue.append(entry.path)
                    }
                }
                guard paths.count < maxFiles, let next = page.nextCursor else { break }
                cursor = next
            }
        }
        return paths
    }
}

extension AppModel {
    /// Demo mode: no host to ask, so the sheet and Inspect get a realistic
    /// synthetic checkout instead.
    var isDemo: Bool { demo != nil }

    /// The chat's checkout root: its own cwd (a worktree resolves to its root
    /// on the host), else its space's path.
    func checkoutRoot(for chat: Chat) -> String? {
        chat.cwd ?? space(for: chat)?.path
    }

    /// One scoped checkout diff for the chat — the host's over the relay, or
    /// demo mode's made-up one.
    func fetchCheckoutDiff(for chat: Chat, mode: CheckoutDiffMode) async throws -> CheckoutDiffSnapshot {
        if isDemo {
            try? await Task.sleep(nanoseconds: 350_000_000)  // feel like a hop
            return CheckoutDiffSnapshot.demo(mode: mode)
        }
        guard let workspace, let cwd = checkoutRoot(for: chat) else { throw RelayError.notConnected }
        return try await workspace.fetchCheckoutDiff(chatId: chat.id, cwd: cwd,
                                                     deviceId: chat.deviceId, mode: mode,
                                                     baseRef: chat.branch)
    }

    /// The checkout's files for the Files segment — the host's directory
    /// listing, or demo mode's made-up project.
    func fetchWorkspaceFiles(for chat: Chat) async throws -> [String] {
        if isDemo {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return DemoInspectSource().projectFiles() ?? []
        }
        guard let workspace else { throw RelayError.notConnected }
        return try await workspace.listWorkspaceFiles(chatId: chat.id, deviceId: chat.deviceId)
    }

    /// Send the batched review prompt into the chat the way the composer
    /// would: a run when the agent is idle, a queued row when a turn is live.
    func sendReviewPrompt(_ prompt: String, for chat: Chat) {
        guard let store = sessionStore(for: chat) else { return }
        let live = effectiveStatus(
            (demo?.sessions[chat.id] ?? workspace?.sessions[chat.id]), now: nowMs()) == .working
        if live {
            store.enqueueMessage(text: prompt, holdForTurnEnd: true)
        } else {
            store.sendRun(prompt: prompt, chat: chat)
        }
    }
}

// MARK: - Demo checkout

extension CheckoutDiffSnapshot {
    /// A realistic synthetic checkout for demo mode: a two-file Rust/Swift
    /// change with hunks, counts and a summary row set, different per mode so
    /// the picker visibly switches scopes.
    static func demo(mode: CheckoutDiffMode) -> CheckoutDiffSnapshot {
        let patch: String
        switch mode {
        case .turn:
            patch = """
            diff --git a/crates/ui/src/shell/mod.rs b/crates/ui/src/shell/mod.rs
            index 1a2b3c4..5d6e7f8 100644
            --- a/crates/ui/src/shell/mod.rs
            +++ b/crates/ui/src/shell/mod.rs
            @@ -120,7 +120,9 @@ pub fn render_status_strip(&self) {
                 let status = self.session_status();
            -    if status.is_working() { self.draw_spinner(); }
            +    // The strip stays reserved at 24pt so the composer never shifts
            +    // while a turn runs (shell.rs render_status_strip).
            +    self.draw_reserved_strip(status);
                 self.draw_composer();
             }
            diff --git a/apps/ios/Harness/Views/SessionView.swift b/apps/ios/Harness/Views/SessionView.swift
            index 9f8e7d6..4c3b2a1 100644
            --- a/apps/ios/Harness/Views/SessionView.swift
            +++ b/apps/ios/Harness/Views/SessionView.swift
            @@ -41,6 +41,7 @@ struct SessionView: View {
                     private var model: AppModel
            +        @Environment(\\.verticalSizeClass) private var verticalSizeClass
                     var body: some View {
            """
        case .branch:
            patch = """
            diff --git a/crates/proto/src/entities.rs b/crates/proto/src/entities.rs
            index 0a1b2c3..3d4e5f6 100644
            --- a/crates/proto/src/entities.rs
            +++ b/crates/proto/src/entities.rs
            @@ -779,6 +779,11 @@ pub struct CheckoutDiff {
                 pub deletions: u32,
            +    /// True when the patch was truncated at the byte cap.
            +    pub truncated: bool,
            +    pub checksum: String,
            +    pub updated_at: DateTime<Utc>,
             }
            diff --git "a/docs/my notes.md" "b/docs/my notes.md"
            new file mode 100644
            index 0000000..ab12cd3
            --- /dev/null
            +++ "b/docs/my notes.md"
            @@ -0,0 +1,2 @@
            +# Notes
            +A quoted path with a space, for the parser.
            """
        case .workingTree:
            patch = """
            diff --git a/apps/ios/Harness/Views/DuoInspect.swift b/apps/ios/Harness/Views/DuoInspect.swift
            index 7c6b5a4..2d1e0f9 100644
            --- a/apps/ios/Harness/Views/DuoInspect.swift
            +++ b/apps/ios/Harness/Views/DuoInspect.swift
            @@ -214,6 +214,9 @@ struct InspectDiffView: View {
                 var body: some View {
            +        // Live checkouts load their own diff here; the transcript's
            +        // edited files remain the fallback.
            +        loadLiveCheckout()
                     if files.isEmpty {
            diff --git a/crates/engine/src/rpc.rs b/crates/engine/src/rpc.rs
            index 5e4f3d2..c8b7a6d 100644
            --- a/crates/engine/src/rpc.rs
            +++ b/crates/engine/src/rpc.rs
            @@ -3027,8 +3027,10 @@ impl Handler {
                     methods::GET_CHECKOUT_DIFF => {
            +        // One-shot scoped capture for the Changes pane.
            +        let mode = p.mode.as_str();
                         Box::pin(async move {
            """
        }
        let files = UnifiedDiffParser.parse(patch).map {
            CheckoutDiffFileSummary(path: $0.path, oldPath: nil, status: "modified",
                                    additions: $0.additions ?? 0, deletions: $0.deletions ?? 0,
                                    binary: false)
        }
        return CheckoutDiffSnapshot(
            checkoutId: "demo-checkout", deviceId: "dev-mac", cwd: "/Users/dev/harness",
            patch: patch, files: files,
            additions: files.reduce(0) { $0 + $1.additions },
            deletions: files.reduce(0) { $0 + $1.deletions },
            truncated: false, checksum: "demo", updatedAt: "2026-01-01T00:00:00Z")
    }
}

// MARK: - Sheet

/// Live checkout changes with inline review comments: mode picker, +/-
/// summary, collapsible file cards of colored hunks, tap-a-line (or range)
/// to comment, and one batched send of everything pending.
struct CheckoutChangesSheet: View {
    let chat: Chat

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: CheckoutDiffMode = .workingTree
    @State private var snapshot: CheckoutDiffSnapshot?
    @State private var loadError: String?
    @State private var loading = false
    @State private var collapsed: Set<String> = []
    @State private var selection: DiffLineSelection?
    @State private var rangeMode = false
    @State private var composing = false
    @State private var draftNote = ""
    @State private var editingComment: DiffReviewComment?
    @StateObject private var reviewStore: DiffReviewDraftStore
    /// Chat rows keep the checkout alive; demo mode never invalidates.
    private let refreshInterval: Duration = .seconds(5)

    init(chat: Chat) {
        self.chat = chat
        _reviewStore = StateObject(wrappedValue: DiffReviewDraftStore.of(chat.id))
    }

    private var files: [InspectFile] { snapshot?.parsedFiles ?? [] }
    private var comments: [DiffReviewComment] { reviewStore.comments(for: chat.id) }

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot {
                    changesList(snapshot)
                } else if loading {
                    ProgressView("Loading changes…")
                        .font(Theme.sans(14))
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load changes", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ContentUnavailableView("No changes",
                                           systemImage: "checkmark.circle",
                                           description: Text("The checkout is clean."))
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .harnessAppearance()
        .task(id: mode) { await load() }
    }

    private func changesList(_ snapshot: CheckoutDiffSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 10, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(files) { file in
                        fileCard(file)
                    }
                } header: {
                    summaryHeader(snapshot)
                }
                if snapshot.truncated {
                    Label("Partial snapshot — the patch was truncated on the host",
                          systemImage: "scissors")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, comments.isEmpty ? 20 : 96)
        }
        .safeAreaInset(edge: .bottom) { reviewTray }
        .refreshable { await load() }
    }

    // MARK: Header

    private func summaryHeader(_ snapshot: CheckoutDiffSnapshot) -> some View {
        VStack(spacing: 8) {
            Picker("Scope", selection: $mode) {
                ForEach(CheckoutDiffMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Text(files.count == 1 ? "1 file" : "\(files.count) files")
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Text("+\(snapshot.additions)")
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.statusCompleted)
                Text("-\(snapshot.deletions)")
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.danger)
                Spacer(minLength: 8)
                if rangeMode {
                    Button {
                        rangeMode = false
                        if let selection { self.selection = .line(selection.bounds.lowerBound, in: selection.path) }
                    } label: {
                        Label("Range", systemImage: "arrow.up.and.down.text.horizontal")
                            .font(Theme.sans(12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("checkout-range-mode")
                } else {
                    Button {
                        rangeMode = true
                    } label: {
                        Label("Range", systemImage: "arrow.up.and.down.text.horizontal")
                            .font(Theme.sans(12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("checkout-range-mode")
                }
            }
        }
        .padding(.vertical, 8)
        .background(Theme.bg)
    }

    // MARK: File card

    private func fileCard(_ file: InspectFile) -> some View {
        let open = !collapsed.contains(file.path)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if collapsed.contains(file.path) { collapsed.remove(file.path) }
                else { collapsed.insert(file.path) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.textFaint)
                    Text(file.path)
                        .font(Theme.mono(12.5))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let adds = file.additions {
                        Text("+\(adds)").font(Theme.mono(12)).foregroundStyle(Theme.statusCompleted)
                    }
                    if let dels = file.deletions {
                        Text("-\(dels)").font(Theme.mono(12)).foregroundStyle(Theme.danger)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(open ? "Collapse" : "Expand") \(file.path)")
            .accessibilityIdentifier("checkout-file-\(file.path)")
            if open {
                Rectangle().fill(Theme.border).frame(height: 1)
                if let hunks = file.hunks, !hunks.isEmpty {
                    ScrollView([.horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(hunks) { hunk in
                                hunkBody(file, hunk)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    Text("No line diff for this file (binary or truncated on the host).")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                        .padding(12)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func hunkBody(_ file: InspectFile, _ hunk: DiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ForEach(hunk.lines) { line in
                reviewableLine(file, hunk, line)
            }
        }
    }

    /// One diff row: compact line numbers, syntax-colored text on the diff
    /// tint, selected-line ring, and pending-comment markers.
    private func reviewableLine(_ file: InspectFile, _ hunk: DiffHunk, _ line: DiffLine) -> some View {
        let number = line.newNumber ?? line.oldNumber
        let selected = selection.map { $0.path == file.path && $0.bounds.contains(number ?? -1) } ?? false
        let commented = comments.contains {
            $0.selection.path == file.path && $0.selection.bounds.contains(number ?? -1)
        }
        let tint: Color = line.kind == .added ? Theme.statusCompleted
            : line.kind == .removed ? Theme.danger : .clear
        return Button {
            tap(file: file, hunk: hunk, line: line, number: number)
        } label: {
            HStack(spacing: 0) {
                Text(line.oldNumber.map { String($0) } ?? "")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 26, alignment: .trailing)
                    .monospacedDigit()
                Text(line.newNumber.map { String($0) } ?? "")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 26, alignment: .trailing)
                    .monospacedDigit()
                highlightedText(line, path: file.path)
                    .font(Theme.mono(12))
                    .fixedSize()
                Spacer(minLength: 0)
                if commented {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .padding(.trailing, 8)
                }
            }
            .padding(.vertical, 1)
            .background(selected ? Theme.accent.opacity(0.18) : tint.opacity(0.10))
            .overlay(alignment: .leading) {
                if line.kind != .context { Rectangle().fill(tint).frame(width: 2) }
            }
            .overlay(alignment: .trailing) {
                if selected { Rectangle().fill(Theme.accent).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Context") line \(number.map(String.init) ?? ""), \(line.text)")
        .accessibilityHint("Tap to select for a review comment")
        .accessibilityIdentifier("checkout-diff-line")
    }

    /// Syntax-colored text for a diff row: the `+`/`-`/space marker keeps its
    /// diff tint, the code after it is tokenized (Highlight) in the file's
    /// language.
    @ViewBuilder
    private func highlightedText(_ line: DiffLine, path: String?) -> some View {
        let marker = line.kind == .context ? " " : (line.kind == .added ? "+" : "-")
        let markerColor = line.kind == .added ? Theme.statusCompleted
            : line.kind == .removed ? Theme.danger : Theme.textFaint
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(marker).foregroundStyle(markerColor)
            HighlightedCodeLine(text: line.text, language: language(for: path))
        }
    }

    private func language(for path: String?) -> HighlightLanguage {
        guard let path else { return .swift }
        return HighlightLanguage.forTag((path as NSString).pathExtension)
            ?? HighlightLanguage.forTag("txt") ?? .swift
    }

    // MARK: Selection

    private func tap(file: InspectFile, hunk: DiffHunk, line: DiffLine, number: Int?) {
        guard let number else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        guard rangeMode else {
            // Single-line mode: tap selects the line and opens the note;
            // tapping the already-selected line clears it.
            if selection == .line(number, in: file.path) {
                selection = nil
            } else {
                selection = .line(number, in: file.path)
                openComposer(for: file, hunk: hunk, range: .line(number, in: file.path))
            }
            return
        }
        // Range mode: taps expand/trim a contiguous range; a second tap on an
        // edge trims that line off; the composer opens from the tray.
        if let current = selection, current.path == file.path,
           current.bounds.contains(number),
           number == current.bounds.lowerBound || number == current.bounds.upperBound {
            selection = current.excluding(number, in: file.path)
        } else if let current = selection, current.path == file.path {
            selection = current.including(number, in: file.path)
        } else {
            selection = .line(number, in: file.path)
        }
    }

    private func openComposer(for file: InspectFile, hunk: DiffHunk, range: DiffLineSelection) {
        draftNote = ""
        editingComment = nil
        composing = true
    }

    /// The quoted rows a comment covers, from the live hunks.
    private func quotedLines(for selection: DiffLineSelection) -> [String] {
        guard let file = files.first(where: { $0.path == selection.path }),
              let hunks = file.hunks else { return [] }
        var rows: [String] = []
        for hunk in hunks {
            for line in hunk.lines {
                let number = line.newNumber ?? line.oldNumber
                guard let number, selection.bounds.contains(number) else { continue }
                let marker = line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
                rows.append(marker + line.text)
            }
        }
        return rows
    }

    // MARK: Tray + composer

    private var reviewTray: some View {
        VStack(spacing: 0) {
            if let selection, rangeMode {
                Button {
                    openComposer(for: files.first { $0.path == selection.path } ?? InspectFile(path: selection.path, additions: nil, deletions: nil, hunks: []),
                                 hunk: DiffHunk(header: "", lines: []), range: selection)
                } label: {
                    Label("Comment on \(selection.label)", systemImage: "text.bubble")
                        .font(Theme.sans(14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            if !comments.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        commentRow(comment)
                    }
                }
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
                .padding(.horizontal, 14)
                .padding(.top, 8)
                HStack(spacing: 8) {
                    Button(role: .destructive) {
                        reviewStore.clear(chatId: chat.id)
                    } label: {
                        Text("Discard all")
                            .font(Theme.sans(13))
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        sendComments()
                    } label: {
                        Text("Send \(comments.count) comment\(comments.count == 1 ? "" : "s")")
                            .font(Theme.sans(14, weight: .semibold))
                            .foregroundStyle(Theme.bg)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(Theme.text, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("checkout-send-comments")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .background(Theme.surface.ignoresSafeArea(.container, edges: .bottom))
        .sheet(isPresented: $composing) { composerSheet }
    }

    private func commentRow(_ comment: DiffReviewComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.selection.label)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(comment.note)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                editingComment = comment
                draftNote = comment.note
                composing = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit comment")
            Button {
                reviewStore.remove(id: comment.id, chatId: chat.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove comment")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var composerSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let target = editingComment?.selection ?? selection {
                    Text(target.label)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.textMuted)
                    ScrollView([.horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(quotedLines(for: target), id: \.self) { row in
                                Text(row)
                                    .font(Theme.mono(12))
                                    .foregroundStyle(row.hasPrefix("+") ? Theme.statusCompleted
                                        : row.hasPrefix("-") ? Theme.danger : Theme.textMuted)
                                    .fixedSize()
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ink(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxHeight: 140)
                }
                TextEditor(text: $draftNote)
                    .font(Theme.sans(15))
                    .frame(maxHeight: .infinity)
                    .padding(4)
                    .background(ink(0.02), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("checkout-comment-editor")
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(editingComment == nil ? "Review comment" : "Edit comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { composing = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingComment == nil ? "Add" : "Save") {
                        saveComment()
                    }
                    .disabled(draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("checkout-comment-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .harnessAppearance()
    }

    private func saveComment() {
        let note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        if let editing = editingComment {
            reviewStore.update(note: note, for: editing.id, chatId: chat.id)
        } else if let selection {
            reviewStore.add(DiffReviewComment(selection: selection, note: note,
                                              quotedLines: quotedLines(for: selection)),
                            for: chat.id)
        }
        editingComment = nil
        composing = false
        selection = nil
        rangeMode = false
    }

    private func sendComments() {
        let prompt = DiffReviewPrompt.prompt(comments: comments, mode: mode)
        model.sendReviewPrompt(prompt, for: chat)
        reviewStore.clear(chatId: chat.id)
        selection = nil
        dismiss()
    }

    // MARK: Loading

    private func load() async {
        loading = snapshot == nil
        loadError = nil
        do {
            let next = try await model.fetchCheckoutDiff(for: chat, mode: mode)
            if !Task.isCancelled {
                snapshot = next
                collapsed = []
            }
        } catch {
            if !Task.isCancelled, snapshot == nil {
                loadError = error.localizedDescription
            }
        }
        loading = false
    }
}

// MARK: - Syntax-colored code line

/// One code row tokenized with the shared Highlighter; paint-only, so the
/// mono layout never moves.
struct HighlightedCodeLine: View {
    let text: String
    let language: HighlightLanguage

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = Theme.text
        let spans = Highlighter.highlight(code: text, language: language).first ?? []
        let charCount = text.count
        for span in spans {
            guard span.range.lowerBound >= 0, span.range.lowerBound < charCount else { continue }
            let upper = min(span.range.upperBound, charCount)
            guard let lower = out.characters.index(out.startIndex, offsetBy: span.range.lowerBound, limitedBy: out.endIndex),
                  let end = out.characters.index(out.startIndex, offsetBy: upper, limitedBy: out.endIndex),
                  lower < end else { continue }
            let color: Color
            switch span.cls {
            case .keyword: color = Theme.tokenKeyword
            case .stringLit: color = Theme.tokenString
            case .comment: color = Theme.textFaint
            case .number: color = Theme.tokenNumber
            }
            out[lower..<end].foregroundColor = color
        }
        return out
    }
}
