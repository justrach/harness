import CLuau
import Foundation
import Observation

enum VisualInput: Sendable {
    case click
    case boolean(Bool)
    case number(Double)
}

indirect enum VisualNode: Equatable, Sendable {
    case column([VisualNode])
    case row([VisualNode])
    case text(String)
    case stat(String)
    case chart(label: String, values: [Double], labels: [String])
    case button(label: String, handlerId: UInt64?)
    case toggle(label: String, value: Bool, handlerId: UInt64?)
    case slider(label: String, value: Double, min: Double, max: Double, handlerId: UInt64?)
    case rule
}

struct VisualLimits {
    static let maxSourceBytes = 64 * 1024
    static let maxTitleChars = 160
    static let maxErrorChars = 360
    static let maxCachedSandboxes = 8
    static let maxChartBars = 12
    static let maxRenderNodes = 512
    static let maxRenderDepth = 24
}

enum VisualRuntimeError: Error, LocalizedError, Equatable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Owns one Luau VM instance. Not thread-safe on its own; callers serialize
/// access on `VisualCache`'s background queue (or call synchronously in tests).
final class VisualSandbox: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(source: String) throws {
        var errBuf = [CChar](repeating: 0, count: 512)
        let bytes = Array(source.utf8)
        let created: OpaquePointer? = bytes.withUnsafeBytes { raw in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
            return cluau_sandbox_create(ptr, bytes.count, &errBuf, errBuf.count)
        }
        guard let created else {
            let msg = String(cString: errBuf)
            throw VisualRuntimeError.failed(msg.isEmpty ? "visual initialization failed" : msg)
        }
        self.handle = created
    }

    deinit {
        if let handle {
            cluau_sandbox_destroy(handle)
        }
    }

    var memoryUsed: Int {
        guard let handle else { return 0 }
        return cluau_sandbox_memory_used(handle)
    }

    func gcCollect() {
        guard let handle else { return }
        cluau_sandbox_gc(handle)
    }

    func render() throws -> VisualNode {
        guard let handle else {
            throw VisualRuntimeError.failed("visual sandbox unavailable")
        }
        var errBuf = [CChar](repeating: 0, count: 512)
        guard let tree = cluau_sandbox_render(handle, &errBuf, errBuf.count) else {
            let msg = String(cString: errBuf)
            throw VisualRuntimeError.failed(msg.isEmpty ? "visual execution failed" : msg)
        }
        defer { cluau_tree_free(tree) }
        return Self.decodeTree(tree)
    }

    func call(handlerId: UInt64, input: VisualInput) throws -> VisualNode {
        guard let handle else {
            throw VisualRuntimeError.failed("visual sandbox unavailable")
        }
        var errBuf = [CChar](repeating: 0, count: 512)
        let tree: UnsafeMutablePointer<CLuauTree>?
        switch input {
        case .click:
            tree = cluau_sandbox_call_click(handle, handlerId, &errBuf, errBuf.count)
        case .boolean(let value):
            tree = cluau_sandbox_call_bool(handle, handlerId, value ? 1 : 0, &errBuf, errBuf.count)
        case .number(let value):
            tree = cluau_sandbox_call_number(handle, handlerId, value, &errBuf, errBuf.count)
        }
        guard let tree else {
            let msg = String(cString: errBuf)
            throw VisualRuntimeError.failed(msg.isEmpty ? "visual execution failed" : msg)
        }
        defer { cluau_tree_free(tree) }
        return Self.decodeTree(tree)
    }

    private static func decodeTree(_ ptr: UnsafeMutablePointer<CLuauTree>) -> VisualNode {
        let tree = ptr.pointee
        guard tree.nodes_count > 0, let nodesPtr = tree.nodes else {
            return .column([])
        }
        return decodeNode(index: 0, tree: tree, nodesPtr: nodesPtr)
    }

    private static func decodeNode(index: Int, tree: CLuauTree, nodesPtr: UnsafeMutablePointer<CLuauNode>) -> VisualNode {
        guard index >= 0, index < tree.nodes_count else { return .text("") }
        let n = nodesPtr[index]
        let text = n.text.map { String(cString: $0) } ?? ""
        let handlerId: UInt64? = n.has_handler != 0 ? n.handler_id : nil

        switch n.kind {
        case CLUAU_NODE_COLUMN:
            return .column(decodeChildren(node: n, tree: tree, nodesPtr: nodesPtr))
        case CLUAU_NODE_ROW:
            return .row(decodeChildren(node: n, tree: tree, nodesPtr: nodesPtr))
        case CLUAU_NODE_TEXT:
            return .text(text)
        case CLUAU_NODE_STAT:
            return .stat(text)
        case CLUAU_NODE_CHART:
            var values: [Double] = []
            if n.values_count > 0, let vPtr = tree.values {
                values.reserveCapacity(n.values_count)
                for i in 0..<n.values_count {
                    values.append(vPtr[n.values_offset + i])
                }
            }
            var labels: [String] = []
            if n.labels_count > 0, let lPtr = tree.chart_labels {
                labels.reserveCapacity(n.labels_count)
                for i in 0..<n.labels_count {
                    labels.append(lPtr[n.labels_offset + i].map { String(cString: $0) } ?? "")
                }
            }
            return .chart(label: text, values: values, labels: labels)
        case CLUAU_NODE_BUTTON:
            return .button(label: text, handlerId: handlerId)
        case CLUAU_NODE_TOGGLE:
            return .toggle(label: text, value: n.value != 0.0, handlerId: handlerId)
        case CLUAU_NODE_SLIDER:
            return .slider(label: text, value: n.value, min: n.min_value, max: n.max_value, handlerId: handlerId)
        case CLUAU_NODE_RULE:
            return .rule
        default:
            return .text("")
        }
    }

    private static func decodeChildren(node: CLuauNode, tree: CLuauTree, nodesPtr: UnsafeMutablePointer<CLuauNode>) -> [VisualNode] {
        guard node.children_count > 0, let idxPtr = tree.child_indices else { return [] }
        var children: [VisualNode] = []
        children.reserveCapacity(node.children_count)
        for i in 0..<node.children_count {
            let childIdx = Int(idxPtr[node.children_offset + i])
            children.append(decodeNode(index: childIdx, tree: tree, nodesPtr: nodesPtr))
        }
        return children
    }
}

enum VisualText {
    static func sanitizePlain(_ input: String, maxChars: Int) -> String {
        var out = ""
        out.reserveCapacity(min(input.count, maxChars))
        var pendingSpace = false
        var count = 0
        for scalar in input.unicodeScalars {
            let isWhitespace = scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7F
            if isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                if count + 1 >= maxChars { break }
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            if count >= maxChars { break }
            out.unicodeScalars.append(scalar)
            count += 1
        }
        return out
    }

    static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-9, abs(rounded) < 1e12 {
            return String(Int64(rounded))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.00$"#, with: "", options: .regularExpression)
    }
}

@MainActor
@Observable
final class VisualEntry {
    enum State: Equatable {
        case loading
        case ready(VisualNode)
        case failed(String)
    }

    let partKey: String
    var title: String
    var script: String
    var state: State = .loading
    var busy = true
    var revision: UInt64 = 1

    @ObservationIgnored var sandbox: VisualSandbox?
    @ObservationIgnored var pendingInput: (handlerId: UInt64, input: VisualInput)?

    init(partKey: String, title: String, script: String) {
        self.partKey = partKey
        self.title = title
        self.script = script
    }
}

@MainActor
@Observable
final class VisualCache {
    private var entries: [String: VisualEntry] = [:]
    private var lruOrder: [String] = []
    @ObservationIgnored private let workerQueue = DispatchQueue(label: "harness.visual.luau", qos: .userInitiated)

    func entry(for partKey: String) -> VisualEntry? {
        entries[partKey]
    }

    func ensureLoaded(partKey: String, title: String, script: String) {
        let cleanTitle = VisualText.sanitizePlain(title, maxChars: VisualLimits.maxTitleChars)
        let effectiveTitle = cleanTitle.isEmpty ? "Native visual" : cleanTitle

        if let existing = entries[partKey] {
            touchLRU(partKey)
            existing.title = effectiveTitle
            if existing.script == script {
                return
            }
            // Source changed: tear down the old sandbox and re-compile on background queue.
            existing.script = script
            existing.revision &+= 1
            existing.sandbox = nil
            existing.pendingInput = nil
            existing.state = .loading
            existing.busy = true
            startLoad(entry: existing, script: script, revision: existing.revision)
            return
        }

        evictIfNeeded()
        let fresh = VisualEntry(partKey: partKey, title: effectiveTitle, script: script)
        entries[partKey] = fresh
        lruOrder.append(partKey)
        startLoad(entry: fresh, script: script, revision: fresh.revision)
    }

    func dispatch(partKey: String, revision: UInt64, handlerId: UInt64, input: VisualInput) {
        guard let entry = entries[partKey], entry.revision == revision else { return }
        touchLRU(partKey)
        if entry.busy {
            // Coalesce rapid updates (such as slider dragging) to the latest value.
            entry.pendingInput = (handlerId, input)
            return
        }
        guard let sandbox = entry.sandbox else { return }
        runCall(entry: entry, sandbox: sandbox, revision: revision, handlerId: handlerId, input: input)
    }

    private func startLoad(entry: VisualEntry, script: String, revision: UInt64) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entry.busy = false
            entry.state = .failed("No script source available for this visual.")
            return
        }
        workerQueue.async {
            do {
                let sb = try VisualSandbox(source: script)
                let root = try sb.render()
                Task { @MainActor [weak self, weak entry] in
                    guard let self, let entry, entry.revision == revision, self.entries[entry.partKey] === entry else { return }
                    entry.sandbox = sb
                    entry.state = .ready(root)
                    entry.busy = false
                }
            } catch {
                let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let clean = VisualText.sanitizePlain(raw, maxChars: VisualLimits.maxErrorChars)
                Task { @MainActor [weak self, weak entry] in
                    guard let self, let entry, entry.revision == revision, self.entries[entry.partKey] === entry else { return }
                    entry.sandbox = nil
                    entry.state = .failed(clean.isEmpty ? "visual execution failed" : clean)
                    entry.busy = false
                }
            }
        }
    }

    private func runCall(entry: VisualEntry, sandbox: VisualSandbox, revision: UInt64, handlerId: UInt64, input: VisualInput) {
        entry.busy = true
        entry.pendingInput = nil
        workerQueue.async {
            do {
                let root = try sandbox.call(handlerId: handlerId, input: input)
                Task { @MainActor [weak self, weak entry] in
                    guard let self, let entry, entry.revision == revision, self.entries[entry.partKey] === entry else { return }
                    entry.state = .ready(root)
                    entry.busy = false
                    if let pending = entry.pendingInput {
                        entry.pendingInput = nil
                        self.dispatchPending(entry: entry, sandbox: sandbox, revision: revision, fallback: pending)
                    }
                }
            } catch {
                let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let clean = VisualText.sanitizePlain(raw, maxChars: VisualLimits.maxErrorChars)
                Task { @MainActor [weak self, weak entry] in
                    guard let self, let entry, entry.revision == revision, self.entries[entry.partKey] === entry else { return }
                    entry.sandbox = nil
                    entry.pendingInput = nil
                    entry.state = .failed(clean.isEmpty ? "visual execution failed" : clean)
                    entry.busy = false
                }
            }
        }
    }

    private func dispatchPending(entry: VisualEntry, sandbox: VisualSandbox, revision: UInt64, fallback: (handlerId: UInt64, input: VisualInput)) {
        // Re-resolve handler id from the freshly rendered tree if needed (sliders keep a single control).
        let targetId: UInt64?
        if case .ready(let root) = entry.state {
            targetId = Self.matchingHandler(in: root, for: fallback.input) ?? fallback.handlerId
        } else {
            targetId = fallback.handlerId
        }
        guard let id = targetId else { return }
        runCall(entry: entry, sandbox: sandbox, revision: revision, handlerId: id, input: fallback.input)
    }

    private static func matchingHandler(in node: VisualNode, for input: VisualInput) -> UInt64? {
        switch (node, input) {
        case (.slider(_, _, _, _, let hid), .number): return hid
        case (.toggle(_, _, let hid), .boolean): return hid
        case (.button(_, let hid), .click): return hid
        case (.column(let children), _), (.row(let children), _):
            for c in children {
                if let found = matchingHandler(in: c, for: input) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private func touchLRU(_ key: String) {
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
        }
        lruOrder.append(key)
    }

    private func evictIfNeeded() {
        while entries.count >= VisualLimits.maxCachedSandboxes, !lruOrder.isEmpty {
            let victim = lruOrder.removeFirst()
            if let entry = entries.removeValue(forKey: victim) {
                let oldSandbox = entry.sandbox
                entry.sandbox = nil
                if let oldSandbox {
                    workerQueue.async { _ = oldSandbox }
                }
            }
        }
    }
}
