// What the open session's agent is doing this turn: its to-do steps, the subagents it runs and the tools it
// uses. A port of the desktop's `agent_work::work` (crates/ui/src/agent_work.rs); the chip beside the running
// indicator and its card (AgentWorkViews) draw it.
//
// Everything comes from the transcript of the current turn (since the last user message):
// - steps are the agent's latest to-do list; the first open item is the active one while the turn streams;
// - the active step's substeps are the tool calls made since that list was last written, and its status word
//   comes from the newest unfinished one;
// - a question the agent is waiting on (an unresolved input request) is the last step, "Asks first";
// - a done step's duration runs between the to-do snapshots that opened and closed it, only when they came
//   from different messages (one streamed message has one timestamp, so nothing rather than a made-up number);
// - agents are subagent spawns with a lifecycle status: every running one in the chat, and those this turn
//   started that have since ended;
// - tool chips are the tool families and MCP servers the turn used.

import Foundation

enum AgentWork {
    /// Substeps shown under the active step, newest last.
    static let maxSubsteps = 3
    /// Step dots on the chip before it switches to "3/9".
    static let maxChipDots = 6
    static let titleMax = 44

    enum StepState: Equatable { case done, active, pending, asksFirst }

    struct Substep: Equatable, Identifiable {
        let id: String
        let title: String
        let done: Bool
    }

    struct Step: Equatable {
        let title: String
        let state: StepState
        /// Measured from to-do snapshots in different messages; nil otherwise.
        let durationMs: Int64?
        /// The active step's verb ("Writing"), from its newest unfinished tool.
        let status: String?
        let substeps: [Substep]
    }

    enum AgentState: Equatable { case running, done, failed, stopped }

    struct Agent: Equatable, Identifiable {
        let id: String
        let title: String
        let state: AgentState
        /// The live tail while it runs; the outcome once it ends.
        let detail: String
    }

    struct ToolChip: Equatable {
        let label: String
        let symbol: String
    }

    struct Work: Equatable {
        var steps: [Step] = []
        var agents: [Agent] = []
        var tools: [ToolChip] = []
        /// The turn is still streaming.
        var live = false

        var isEmpty: Bool { steps.isEmpty && agents.isEmpty }
        var runningAgents: Int { agents.filter { $0.state == .running }.count }
    }

    private struct Snapshot {
        let entry: Int
        let at: Int64
        let items: [TaskItem]
    }

    /// What the chip and card show for `transcript`. Pure: tests call it with synthetic entries.
    static func work(_ transcript: [MessageEntry]) -> Work {
        let scopeStart = transcript.lastIndex { $0.role == .user }.map { $0 + 1 } ?? 0
        let scope = transcript[scopeStart...]
        let live = scope.contains { $0.status == .streaming }

        // To-do snapshots in order, with the message time they arrived at, and the tool calls after the latest.
        var snapshots: [Snapshot] = []
        var sinceTodo: [(id: String, call: RenderToolCall, resolved: Bool)] = []
        var asks: String?
        var tools: [ToolChip] = []
        for (entryIndex, entry) in scope.enumerated() {
            for part in entry.parts {
                switch part {
                case .tool(_, let call, _, _) where call.tag == "todo" && !(call.tasks ?? []).isEmpty:
                    snapshots.append(Snapshot(entry: entryIndex, at: entry.createdAt, items: call.tasks ?? []))
                    sinceTodo.removeAll()
                case .tool(let id, let call, _, let resolved):
                    sinceTodo.append((id, call, resolved))
                    if let chip = toolChip(call), !tools.contains(chip) { tools.append(chip) }
                case .input(_, _, let questions, false):
                    asks = questions.first.map { question in
                        let header = question.header.trimmingCharacters(in: .whitespacesAndNewlines)
                        return firstLine(header.isEmpty ? question.question : header, max: titleMax)
                    }
                default:
                    break
                }
            }
        }

        var agents: [Agent] = []
        for (entryIndex, entry) in transcript.enumerated() {
            for case .tool(let id, let call, _, _) in entry.parts {
                guard call.isSubagentSpawn, let status = call.subagentStatus else { continue }
                let state = agentState(status)
                if state != .running, entryIndex < scopeStart { continue }
                let detail: String
                switch state {
                case .running:
                    let tail = call.subagentTail.map { firstLine($0, max: titleMax) } ?? ""
                    detail = tail.isEmpty ? "Working" : tail
                case .done: detail = "Ready to review"
                case .failed: detail = "Failed"
                case .stopped: detail = "Stopped"
                }
                agents.append(Agent(id: id, title: subagentTitle(call) ?? "Subagent", state: state, detail: detail))
            }
        }

        var steps: [Step] = []
        if let items = snapshots.last?.items {
            let active = live ? items.firstIndex(where: { !$0.done }) : nil
            for (index, item) in items.enumerated() {
                let state: StepState = item.done ? .done : index == active ? .active : .pending
                var substeps: [Substep] = []
                var status: String?
                if state == .active {
                    substeps = sinceTodo.compactMap { tool in
                        substepTitle(tool.call, done: tool.resolved)
                            .map { Substep(id: tool.id, title: $0, done: tool.resolved) }
                    }
                    substeps = Array(substeps.suffix(maxSubsteps))
                    status = asks != nil ? "Waiting" : statusWord(sinceTodo.last { !$0.resolved }?.call)
                }
                steps.append(Step(title: firstLine(item.text, max: titleMax), state: state,
                                  durationMs: stepDuration(snapshots, index: index), status: status,
                                  substeps: substeps))
            }
            if let asks {
                steps.append(Step(title: asks, state: .asksFirst, durationMs: nil, status: nil, substeps: []))
            }
        }

        return Work(steps: steps, agents: agents, tools: tools, live: live)
    }

    /// How long item `index` of the latest list took: from the snapshot where it became the first open item to
    /// the one where it was first seen done, counted only across different messages.
    private static func stepDuration(_ snapshots: [Snapshot], index: Int) -> Int64? {
        guard let latest = snapshots.last, index < latest.items.count else { return nil }
        let text = latest.items[index].text
        guard let doneAt = snapshots.firstIndex(where: { $0.items.contains { $0.text == text && $0.done } }),
              let startedAt = snapshots[..<doneAt].firstIndex(where: { $0.items.first { !$0.done }?.text == text })
        else { return nil }
        let start = snapshots[startedAt], end = snapshots[doneAt]
        return end.entry != start.entry && end.at > start.at ? end.at - start.at : nil
    }

    // MARK: Chip

    /// The chip's dots, one per step, up to `maxChipDots`; nil past that (the chip shows "done/total").
    static func chipDots(_ work: Work) -> [StepState]? {
        let states = work.steps.map(\.state)
        return !states.isEmpty && states.count <= maxChipDots ? states : nil
    }

    /// "2 agents" plus "running", or every agent plus "done" once none runs.
    static func agentsHeader(_ work: Work) -> (count: String, word: String) {
        let running = work.runningAgents
        if running > 0 { return ("\(running) \(running == 1 ? "agent" : "agents")", "running") }
        let count = work.agents.count
        return ("\(count) \(count == 1 ? "agent" : "agents")", "done")
    }

    /// 12s, 1m 5s, 2h 3m.
    static func durationLabel(ms: Int64) -> String {
        let secs = (max(ms, 0) + 500) / 1000
        switch secs {
        case ..<60: return "\(secs)s"
        case ..<3600: return secs % 60 == 0 ? "\(secs / 60)m" : "\(secs / 60)m \(secs % 60)s"
        default: return "\(secs / 3600)h \((secs % 3600) / 60)m"
        }
    }

    // MARK: Tool calls

    /// "Reading x" while it runs, "Read x" once done. Nil for calls that are not work of their own (to-do
    /// updates, compaction).
    static func substepTitle(_ call: RenderToolCall, done: Bool) -> String? {
        func verb(_ running: String, _ finished: String) -> String { done ? finished : running }
        let text: (String, String)
        switch call.tag {
        case "todo": return nil
        case _ where call.isCompaction: return nil
        case "exec": text = (verb("Running", "Ran"), firstLine(call.string("command") ?? "", max: titleMax))
        case "readFile": text = (verb("Reading", "Read"), fileName(call.string("path") ?? ""))
        case "writeFile": text = (verb("Writing", "Wrote"), fileName(call.string("path") ?? ""))
        case "editFile": text = (verb("Editing", "Edited"), fileName(call.string("path") ?? ""))
        case "applyPatch": text = (verb("Patching", "Patched"), call.string("path").map(fileName) ?? "files")
        case "search", "glob":
            text = (verb("Searching", "Searched"), firstLine(call.string("pattern") ?? "", max: titleMax))
        case "webFetch": text = (verb("Fetching", "Fetched"), host(call.string("url") ?? ""))
        case "webSearch":
            text = (verb("Searching the web for", "Searched the web for"),
                    firstLine(call.string("query") ?? "", max: titleMax))
        case _ where call.isSubagentSpawn:
            text = (verb("Delegating", "Delegated"), subagentTitle(call) ?? "a subagent")
        case "mcp": text = (verb("Using", "Used"), "\(call.string("server") ?? "") \(call.string("tool") ?? "")")
        default: text = (verb("Using", "Used"), firstLine(call.string("name") ?? "", max: titleMax))
        }
        return firstLine("\(text.0) \(text.1)", max: titleMax)
    }

    /// The active step's status word, from the tool it is waiting on.
    static func statusWord(_ call: RenderToolCall?) -> String {
        guard let call else { return "Working" }
        switch call.tag {
        case "exec": return "Running"
        case "writeFile", "editFile", "applyPatch": return "Writing"
        case "readFile": return "Reading"
        case "search", "glob": return "Searching"
        case "webFetch", "webSearch": return "Browsing"
        default: return call.isSubagentSpawn ? "Delegating" : "Working"
        }
    }

    static func toolChip(_ call: RenderToolCall) -> ToolChip? {
        switch call.tag {
        case "todo": return nil
        case _ where call.isCompaction: return nil
        case _ where call.isSubagentSpawn: return ToolChip(label: "Agents", symbol: "person.2")
        case "exec": return ToolChip(label: "Terminal", symbol: "terminal")
        case "readFile", "writeFile", "editFile", "applyPatch": return ToolChip(label: "Files", symbol: "doc.text")
        case "search", "glob": return ToolChip(label: "Search", symbol: "magnifyingglass")
        case "webFetch", "webSearch": return ToolChip(label: "Web", symbol: "globe")
        case "mcp":
            let server = call.string("server") ?? ""
            return ToolChip(label: firstLine(server, max: 24),
                            symbol: server.lowercased().contains("git") ? "arrow.triangle.branch" : "square.grid.2x2")
        default: return nil
        }
    }

    private static func agentState(_ status: String) -> AgentState {
        switch status {
        case "running": return .running
        case "done": return .done
        case "cancelled": return .stopped
        default: return .failed  // failed, disconnected
        }
    }

    // MARK: Subagent titles (transcript.rs subagent_tab_title)

    /// The bare task a spawn runs ("scan repo" for "Agent: scan repo"); nil without one. The phone's doc keeps
    /// only the call's name, not its input, so a bare "Agent" has no title.
    static func subagentTitle(_ call: RenderToolCall) -> String? {
        guard let name = call.tag == "mcp" ? call.string("tool") : call.string("name") else { return nil }
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Wait for agent") {
            guard let range = text.range(of: ": ") else { return nil }
            text = String(text[range.upperBound...])
        }
        let title = stripSpawnPrefix(text)
        if title.isEmpty || title.lowercased() == "subagent"
            || (title != text && title.allSatisfy({ $0.isASCII && $0.isNumber })) { return nil }
        let line = firstLine(title, max: 40)
        return line.isEmpty ? nil : line
    }

    /// Drop a leading "Agent"/"Task" genus with its colon; only at a word boundary ("Taskmaster" keeps it).
    private static func stripSpawnPrefix(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["agent", "task"] where t.lowercased().hasPrefix(prefix) {
            let rest = t.dropFirst(prefix.count)
            if rest.isEmpty { return "" }
            if rest.first == ":" || rest.first?.isWhitespace == true {
                return rest.drop(while: { $0 == ":" }).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }

    // MARK: Text

    /// The first non-blank line, trimmed, capped at `max` characters with an ellipsis.
    static func firstLine(_ text: String, max: Int) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }

    private static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    private static func host(_ url: String) -> String {
        let rest = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
        return rest.split(omittingEmptySubsequences: false, whereSeparator: { "/?#".contains($0) })
            .first.map(String.init) ?? rest
    }
}

extension RenderToolCall {
    /// A call that starts a subagent (proto `ToolCall::is_subagent_spawn`): "Agent", or "Agent: <task>".
    var isSubagentSpawn: Bool {
        guard let name = tag == "unknown" ? string("name") : tag == "mcp" ? string("tool") : nil else { return false }
        return name == "Agent" || name.hasPrefix("Agent: ")
    }

    /// The context compaction the engine records as a tool call (proto `COMPACTION_TOOL_NAME`).
    var isCompaction: Bool { tag == "unknown" && string("name") == "Compact context" }

    /// A spawn's lifecycle (`running`, `done`, `failed`, `cancelled`, `disconnected`), from the tool part.
    var subagentStatus: String? { string(Self.subagentStatusKey) }
    /// A running spawn's one-line live tail.
    var subagentTail: String? { string(Self.subagentTailKey) }

    /// Part-level fields the decoder keeps beside the call's own (prefixed so no call field collides).
    static let subagentStatusKey = "part.subagentStatus"
    static let subagentTailKey = "part.subagentTail"
}
