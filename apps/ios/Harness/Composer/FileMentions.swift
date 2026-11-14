// @file / @folder mention autocomplete and question-dismissal transport.

import Foundation
import Loro
import SwiftUI

struct WorkspaceFileCandidate: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case file
        case directory
        case symlink
    }

    var id: String { path }
    let path: String
    let name: String
    let kind: Kind

    var isDir: Bool { kind == .directory }

    /// Parent path relative to workspace root (empty for root-level entries).
    var parentPath: String {
        let trimmed = Self.trimTrailingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[..<slash])
    }

    init(path: String, name: String? = nil, kind: Kind = .file) {
        let cleaned = Self.trimTrailingSlashes(path)
        self.path = cleaned
        if let name, !name.isEmpty {
            self.name = name
        } else {
            let last = cleaned.split(separator: "/").last.map(String.init) ?? cleaned
            self.name = last.isEmpty ? cleaned : last
        }
        self.kind = kind
    }

    private static func trimTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

struct MentionIndex: Equatable, Sendable {
    static let fileMentionScheme = "harness-file:"

    private(set) var entries: [String: WorkspaceFileCandidate] = [:]
    private var pathToToken: [String: String] = [:]
    private var pathsByBasename: [String: [String]] = [:]

    init(candidates: [WorkspaceFileCandidate] = []) {
        observe(candidates)
    }

    mutating func observe(_ candidates: [WorkspaceFileCandidate]) {
        for candidate in candidates {
            let key = Self.basename(for: candidate)
            var existing = pathsByBasename[key] ?? []
            if !existing.contains(candidate.path) {
                existing.append(candidate.path)
                pathsByBasename[key] = existing
            }
        }
    }

    mutating func clear() {
        entries.removeAll()
        pathToToken.removeAll()
        pathsByBasename.removeAll()
    }

    /// Detect an active `@query` ending at `cursor` (UTF-16 offset) after
    /// start-of-string, space, or newline. Email addresses like `foo@bar` do
    /// not trigger because `@` is preceded by a non-whitespace character.
    static func activeQuery(in text: String, cursor: Int) -> (range: NSRange, query: String)? {
        let ns = text as NSString
        let clamped = min(max(cursor, 0), ns.length)
        guard clamped > 0 else { return nil }

        var atIndex: Int?
        var index = clamped
        while index > 0 {
            let unit = ns.character(at: index - 1)
            if unit == 0x40 { // '@'
                atIndex = index - 1
                break
            }
            if let scalar = UnicodeScalar(unit),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }
            index -= 1
        }

        guard let at = atIndex else { return nil }
        if at > 0 {
            let prevUnit = ns.character(at: at - 1)
            guard let prevScalar = UnicodeScalar(prevUnit),
                  CharacterSet.whitespacesAndNewlines.contains(prevScalar) else {
                return nil
            }
        }

        let range = NSRange(location: at, length: clamped - at)
        let queryStart = at + 1
        let query = clamped > queryStart
            ? ns.substring(with: NSRange(location: queryStart, length: clamped - queryStart))
            : ""
        return (range: range, query: query)
    }

    /// Generate a `@basename` token for `file`, disambiguating basename
    /// collisions as `@parent/basename` (walking up segments if needed).
    mutating func token(for file: WorkspaceFileCandidate) -> String {
        if let existing = pathToToken[file.path] {
            return existing
        }
        observe([file])

        let base = Self.basename(for: file)
        let knownCount = pathsByBasename[base]?.count ?? 0
        let segments = Self.trimmedPath(file.path)
            .split(separator: "/")
            .map(String.init)

        var depth = knownCount > 1 ? 2 : 1
        let maxDepth = max(segments.count, 1)
        var candidateToken = Self.makeToken(segments: segments, depth: depth, fallback: base)

        while depth < maxDepth,
              let owner = entries[candidateToken],
              owner.path != file.path {
            depth += 1
            candidateToken = Self.makeToken(segments: segments, depth: depth, fallback: base)
        }

        // If the parent-qualified token still collides (e.g. a previously
        // inserted `@Config.swift` exists alongside a new file), keep adding
        // parent segments or fall back to full path.
        if let owner = entries[candidateToken], owner.path != file.path {
            candidateToken = "@\(Self.trimmedPath(file.path))"
        }

        entries[candidateToken] = file
        pathToToken[file.path] = candidateToken
        return candidateToken
    }

    /// Replace live `@token` references in `text` with Harness's canonical
    /// markdown file-mention links (`crates/proto/src/file_mentions.rs`).
    func encode(_ text: String) -> String {
        guard !entries.isEmpty, text.contains("@") else { return text }
        let orderedTokens = entries.keys.sorted { $0.utf16.count > $1.utf16.count }
        let ns = text as NSString
        let length = ns.length
        var out = ""
        var cursor = 0

        while cursor < length {
            let unit = ns.character(at: cursor)
            if unit == 0x40, isLeadingBoundary(in: ns, at: cursor) {
                var matched = false
                for token in orderedTokens {
                    let tokenLen = (token as NSString).length
                    guard cursor + tokenLen <= length else { continue }
                    let candidateRange = NSRange(location: cursor, length: tokenLen)
                    if ns.substring(with: candidateRange) == token,
                       isTrailingBoundary(in: ns, after: cursor + tokenLen),
                       let file = entries[token] {
                        out += Self.canonicalLink(for: file)
                        cursor += tokenLen
                        matched = true
                        break
                    }
                }
                if matched { continue }
            }
            let range = ns.rangeOfComposedCharacterSequence(at: cursor)
            out += ns.substring(with: range)
            cursor = NSMaxRange(range)
        }
        return out
    }

    /// Matches `harness_proto::file_mentions::local_file_link` byte-for-byte
    /// for safe workspace-relative paths.
    static func canonicalLink(for file: WorkspaceFileCandidate) -> String {
        let trimmed = trimmedPath(file.path)
        let base = basename(for: file)
        let escaped = escapeMentionLabel(base)
        let suffixed = file.isDir && !trimmed.hasSuffix("/") ? "\(trimmed)/" : trimmed
        let encoded = percentEncodePath(suffixed)
        if localPathIsSafe(trimmed) {
            return "[\(escaped)](\(fileMentionScheme)\(encoded))"
        }
        return "[\(escaped)](\(encoded))"
    }

    static func localPathIsSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        for scalar in path.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    private static func trimmedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func basename(for file: WorkspaceFileCandidate) -> String {
        let trimmed = trimmedPath(file.path)
        if let last = trimmed.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return file.name.isEmpty ? trimmed : file.name
    }

    private static func makeToken(segments: [String], depth: Int, fallback: String) -> String {
        guard !segments.isEmpty else { return "@\(fallback)" }
        let slice = segments.suffix(min(depth, segments.count))
        return "@\(slice.joined(separator: "/"))"
    }

    private static func escapeMentionLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func percentEncodePath(_ path: String) -> String {
        var out = ""
        for byte in path.utf8 {
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A) // a-z
                || (byte >= 0x30 && byte <= 0x39) // 0-9
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E || byte == 0x2F // - . _ ~ /
            if isUnreserved {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private func isLeadingBoundary(in ns: NSString, at index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let scalar = UnicodeScalar(ns.character(at: index - 1)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func isTrailingBoundary(in ns: NSString, after index: Int) -> Bool {
        guard index < ns.length else { return true }
        let unit = ns.character(at: index)
        guard let scalar = UnicodeScalar(unit) else { return false }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        // Sentence punctuation after a token (e.g. `@Config.swift,`) is a boundary,
        // except `.` followed by an identifier character (e.g. `@Config.swift` vs `@Config`).
        let trailingPunctuation = CharacterSet(charactersIn: ",:;!?)]}\"'`")
        if trailingPunctuation.contains(scalar) {
            return true
        }
        if scalar == "." {
            guard index + 1 < ns.length,
                  let nextScalar = UnicodeScalar(ns.character(at: index + 1)) else {
                return true
            }
            return !CharacterSet.alphanumerics.contains(nextScalar)
        }
        return false
    }
}

// MARK: - Workspace File Search & Suggestions Bar

enum WorkspaceMentionSearch {
    private struct SearchMatchWire: Decodable {
        let path: String
        let name: String
        let kind: WorkspaceFileCandidate.Kind
    }

    private struct DirectoryPageWire: Decodable {
        let entries: [SearchMatchWire]
    }

    static let demoFallbackFiles: [WorkspaceFileCandidate] = [
        WorkspaceFileCandidate(path: "apps/ios/Harness/Composer/ComposerView.swift", kind: .file),
        WorkspaceFileCandidate(path: "apps/ios/Harness/Composer/Attachments.swift", kind: .file),
        WorkspaceFileCandidate(path: "apps/ios/Harness/Composer/FileMentions.swift", kind: .file),
        WorkspaceFileCandidate(path: "apps/ios/Harness/Views/SessionView.swift", kind: .file),
        WorkspaceFileCandidate(path: "crates/proto/src/file_mentions.rs", kind: .file),
        WorkspaceFileCandidate(path: "crates/engine/src/workspace_files.rs", kind: .file),
        WorkspaceFileCandidate(path: "apps", kind: .directory),
        WorkspaceFileCandidate(path: "crates", kind: .directory),
        WorkspaceFileCandidate(path: "docs", kind: .directory),
    ]

    static func fallbackMatches(query: String, limit: Int = 6) -> [WorkspaceFileCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = demoFallbackFiles
        guard !trimmed.isEmpty else {
            return Array(pool.prefix(limit))
        }
        let scored = pool.compactMap { candidate -> (Int, WorkspaceFileCandidate)? in
            let lowerPath = candidate.path.lowercased()
            let lowerName = candidate.name.lowercased()
            if lowerName.hasPrefix(trimmed) { return (0, candidate) }
            if lowerName.contains(trimmed) { return (1, candidate) }
            if lowerPath.contains(trimmed) { return (2, candidate) }
            return nil
        }
        return Array(scored.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1.path < $1.1.path
        }.map(\.1).prefix(limit))
    }

    static func search(relay: DeviceRelayClient?, chatId: String, spaceId: String?,
                       query: String, isDemo: Bool, limit: Int = 6) async -> [WorkspaceFileCandidate] {
        if isDemo || relay == nil {
            return fallbackMatches(query: query, limit: limit)
        }
        guard let relay else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var targetParams: [String: Any] = [:]
        if !chatId.isEmpty {
            targetParams["chatId"] = chatId
        } else if let spaceId, !spaceId.isEmpty {
            targetParams["spaceId"] = spaceId
        } else {
            return []
        }

        if trimmed.isEmpty {
            var params = targetParams
            params["directory"] = ""
            params["includeIgnored"] = false
            if let page: DirectoryPageWire = try? await relay.call(
                method: "ListWorkspaceDirectory", params: params, timeoutSeconds: 5
            ) {
                return page.entries.prefix(limit).map {
                    WorkspaceFileCandidate(path: $0.path, name: $0.name, kind: $0.kind)
                }
            }
            return []
        }

        var params = targetParams
        params["query"] = trimmed
        params["includeIgnored"] = false
        params["limit"] = limit
        if let matches: [SearchMatchWire] = try? await relay.call(
            method: "SearchWorkspaceFiles", params: params, timeoutSeconds: 5
        ) {
            return matches.prefix(limit).map {
                WorkspaceFileCandidate(path: $0.path, name: $0.name, kind: $0.kind)
            }
        }
        return []
    }
}

struct MentionSuggestionsBar: View {
    @Environment(AppModel.self) private var model: AppModel?
    let query: String?
    let deviceId: String
    let chatId: String
    var spaceId: String? = nil
    var onCandidatesLoaded: ([WorkspaceFileCandidate]) -> Void = { _ in }
    let onSelect: (WorkspaceFileCandidate) -> Void

    @State private var suggestions: [WorkspaceFileCandidate] = []

    var body: some View {
        Group {
            if query != nil, !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(suggestions.prefix(6).enumerated()), id: \.element.id) { ix, file in
                            Button {
                                onSelect(file)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: file.isDir ? "folder" : "doc.text")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.textMuted)
                                    Text(file.name)
                                        .font(Theme.sans(13, weight: .medium))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    if !file.parentPath.isEmpty {
                                        Text(file.parentPath)
                                            .font(Theme.sans(11))
                                            .foregroundStyle(Theme.textFaint)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                            .frame(maxWidth: 110, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .glassEffect(.regular.interactive(), in: Capsule())
                            }
                            .buttonStyle(PressScaleButtonStyle(scale: 0.96))
                            .accessibilityLabel("\(file.isDir ? "Folder" : "File") \(file.path)")
                            .accessibilityIdentifier("mention-\(ix)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mention-suggestions")
                .transition(.opacity)
            }
        }
        .task(id: "\(deviceId)|\(chatId)|\(query ?? "")") {
            guard let query else {
                suggestions = []
                return
            }
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let relay = model?.workspace?.relay(for: deviceId)
            let isDemo = model?.demo != nil
            let results = await WorkspaceMentionSearch.search(
                relay: relay, chatId: chatId, spaceId: spaceId,
                query: query, isDemo: isDemo, limit: 6
            )
            guard !Task.isCancelled else { return }
            suggestions = Array(results.prefix(6))
            onCandidatesLoaded(suggestions)
        }
    }
}

// MARK: - Question dismissal transport (`dismissInput`)

struct DismissInputCommand: Codable, Equatable, Sendable {
    var kind: String = "dismissInput"
    let requestId: String
}

struct QueueDismissInputParams: Codable, Equatable, Sendable {
    let chatId: String
    let command: DismissInputCommand
}

extension AppModel {
    nonisolated static func dismissInputRequestParams(chatId: String, requestId: String) -> QueueDismissInputParams {
        QueueDismissInputParams(
            chatId: chatId,
            command: DismissInputCommand(requestId: requestId)
        )
    }

    func dismissInput(requestId: String) {
        if let demo {
            let candidates = demo.chats.filter {
                demo.sessions[$0.id]?.status == .awaitingInput || $0.id == "chat-picker"
            }
            for chat in candidates {
                let store = demo.sessionStore(for: chat.id)
                if store.openInputRequest?.requestId == requestId {
                    resolveDemoInput(store: store, chatId: chat.id, requestId: requestId)
                    return
                }
            }
            return
        }

        guard let workspace else { return }
        let awaitingChats = workspace.chats.filter {
            workspace.sessions[$0.id]?.status == .awaitingInput
        }
        for chat in awaitingChats {
            let store = sessionStore(for: chat)
            if store?.openInputRequest?.requestId == requestId {
                dismissInput(chatId: chat.id, deviceId: chat.deviceId, requestId: requestId, store: store)
                return
            }
        }
    }

    func dismissInput(chatId: String, deviceId: String, requestId: String, store: SessionStore? = nil) {
        if demo != nil, let store {
            resolveDemoInput(store: store, chatId: chatId, requestId: requestId)
            return
        }

        if let store {
            let commands = store.doc.getList(id: "commands")
            let payload: [String: Any] = [
                "kind": "dismissInput",
                "requestId": requestId,
            ]
            do {
                let map = try commands.pushContainer(child: LoroMap())
                try map.insert(key: "id", v: UUID().uuidString.lowercased())
                try map.insert(key: "kind", v: "dismissInput")
                try map.insert(key: "payload", v: LoroValue.fromJSON(payload))
                try map.insert(key: "issuedBy", v: store.deviceId)
                try map.insert(key: "issuedAt", v: nowMs())
                if let turnId = store.lastEntryId {
                    try map.insert(key: "basedOn", v: LoroValue.map(value: [
                        "turnId": .string(value: turnId),
                        "frontier": .null,
                    ]))
                }
                try map.insert(key: "expiresAt", v: nowMs() + commandDefaultTtlMs)
                try map.insert(key: "status", v: "pending")
                store.doc.commit()
            } catch {}
            store.nudgeHost()
        }

        if let workspace {
            let relay = workspace.relay(for: deviceId)
            Task {
                struct Reply: Decodable { var commandId: String? }
                let _: Reply? = try? await relay.call(
                    method: "QueueCommand",
                    params: [
                        "chatId": chatId,
                        "command": [
                            "kind": "dismissInput",
                            "requestId": requestId,
                        ],
                    ]
                )
            }
        }
    }

    private func resolveDemoInput(store: SessionStore, chatId: String, requestId: String) {
        let updated = store.entries.map { entry -> MessageEntry in
            var copy = entry
            copy.parts = entry.parts.map { part in
                if case .input(let id, let reqId, let questions, _) = part, reqId == requestId {
                    return .input(id: id, requestId: reqId, questions: questions, resolved: true)
                }
                return part
            }
            return copy
        }
        store.setEntries(updated)
        if var row = demo?.sessions[chatId] {
            row.status = .idle
            row.updatedAt = nowMs()
            demo?.sessions[chatId] = row
        }
    }
}
