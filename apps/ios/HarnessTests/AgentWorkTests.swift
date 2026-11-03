import XCTest
@testable import Harness

/// The agent work chip and card: what the turn's agent is doing, from the transcript. Ports the desktop's
/// `agent_work` tests; parts go through the sync decoder, so the subagent fields riding the part are covered.
final class AgentWorkTests: XCTestCase {
    private func part(_ json: [String: Any]) -> MessagePart {
        SessionStore.partFrom(.fromJSON(json))!
    }

    private func entry(_ id: String, _ role: MessageRole, at: Int64, _ status: MessageStatus,
                       _ parts: [[String: Any]]) -> MessageEntry {
        MessageEntry(id: id, role: role, parts: parts.map(part), createdAt: at, deviceId: "d", status: status)
    }

    private func ask() -> MessageEntry {
        entry("u", .user, at: 0, .complete, [["id": "t", "kind": "text", "text": "go"]])
    }

    private func todo(_ id: String, _ items: [(String, Bool)]) -> [String: Any] {
        ["id": id, "kind": "tool", "isError": false,
         "call": ["kind": "todo", "items": items.map { ["text": $0.0, "done": $0.1] }]]
    }

    private func tool(_ id: String, _ call: [String: Any], resolved: Bool = true) -> [String: Any] {
        var json: [String: Any] = ["id": id, "kind": "tool", "call": call]
        if resolved { json["isError"] = false }
        return json
    }

    func testNoTodoListMeansNoSteps() {
        let work = AgentWork.work([
            ask(),
            entry("a", .assistant, at: 1, .streaming, [tool("r", ["kind": "readFile", "path": "a.rs"])]),
        ])
        XCTAssertTrue(work.steps.isEmpty)
        XCTAssertTrue(work.isEmpty)
        XCTAssertEqual(work.tools, [AgentWork.ToolChip(label: "Files", symbol: "doc.text")])
    }

    func testTheLatestTodoListSetsTheStepsAndTheActiveStepsSubsteps() {
        let work = AgentWork.work([
            ask(),
            entry("a1", .assistant, at: 1_000, .complete,
                  [todo("t1", [("Collect", false), ("Draft", false), ("Check", false)])]),
            entry("a2", .assistant, at: 13_000, .complete, [
                todo("t2", [("Collect", true), ("Draft", false), ("Check", false)]),
                tool("old", ["kind": "exec", "command": "ls"]),
            ]),
            entry("a3", .assistant, at: 14_000, .streaming, [
                todo("t3", [("Collect", true), ("Draft", false), ("Check", false)]),
                tool("w1", ["kind": "webFetch", "url": "https://example.invalid/fees"]),
                tool("w2", ["kind": "writeFile", "path": "docs/overview.md"]),
                tool("w3", ["kind": "editFile", "path": "docs/validators.md"], resolved: false),
            ]),
        ])
        XCTAssertTrue(work.live)
        XCTAssertEqual(work.steps.map(\.state), [.done, .active, .pending])
        XCTAssertEqual(work.steps[0].durationMs, 12_000)
        XCTAssertEqual(work.steps[1].status, "Writing")
        XCTAssertEqual(work.steps[1].substeps.map(\.title),
                       ["Fetched example.invalid", "Wrote overview.md", "Editing validators.md"])
        XCTAssertEqual(work.steps[1].substeps.map(\.done), [true, true, false])
        XCTAssertTrue(work.steps[0].substeps.isEmpty && work.steps[2].substeps.isEmpty)
    }

    func testDurationsNeedTwoMessages() {
        // Opened and closed inside one streamed message: one timestamp, so no duration rather than a made-up one.
        let work = AgentWork.work([
            ask(),
            entry("a", .assistant, at: 5_000, .streaming, [
                todo("t1", [("Only", false), ("Next", false)]),
                todo("t2", [("Only", true), ("Next", false)]),
            ]),
        ])
        XCTAssertEqual(work.steps[0].state, .done)
        XCTAssertNil(work.steps[0].durationMs)
    }

    func testAFinishedTurnHasNoActiveStep() {
        let work = AgentWork.work([
            ask(), entry("a", .assistant, at: 1, .complete, [todo("t1", [("One", true), ("Two", false)])]),
        ])
        XCTAssertEqual(work.steps.map(\.state), [.done, .pending])
    }

    func testANewUserMessageStartsANewTurn() {
        let work = AgentWork.work([
            ask(), entry("a", .assistant, at: 1, .complete, [todo("t1", [("Old", false)])]), ask(),
        ])
        XCTAssertTrue(work.steps.isEmpty)
    }

    func testAPendingQuestionIsTheGatedStep() {
        let question: [String: Any] = ["id": "q", "kind": "input", "requestId": "r", "resolved": false,
                                       "questions": [["id": "q1", "header": "Send to team", "question": "Send it?",
                                                      "options": ["Yes", "No"]]]]
        let work = AgentWork.work([
            ask(), entry("a", .assistant, at: 1, .streaming, [todo("t1", [("Draft", true), ("Send", false)]), question]),
        ])
        XCTAssertEqual(work.steps.last?.state, .asksFirst)
        XCTAssertEqual(work.steps.last?.title, "Send to team")
        XCTAssertEqual(work.steps[1].status, "Waiting")
    }

    func testAnAnsweredQuestionIsNotGated() {
        let question: [String: Any] = ["id": "q", "kind": "input", "requestId": "r", "resolved": true,
                                       "questions": [["id": "q1", "header": "Send", "question": "Send it?",
                                                      "options": [String]()]]]
        let work = AgentWork.work([
            ask(), entry("a", .assistant, at: 1, .streaming, [todo("t1", [("Draft", false)]), question]),
        ])
        XCTAssertFalse(work.steps.contains { $0.state == .asksFirst })
    }

    func testSubagentsShowEveryRunningOneAndThisTurnsFinishedOnes() {
        func spawn(_ id: String, _ name: String, _ status: String, tail: String? = nil) -> [String: Any] {
            var json = tool(id, ["kind": "unknown", "name": name])
            json["subagentStatus"] = status
            if let tail { json["subagentTail"] = tail }
            return json
        }
        let work = AgentWork.work([
            ask(),
            entry("a0", .assistant, at: 1, .complete, [
                spawn("s0", "Agent: Earlier done", "done"),
                spawn("s1", "Agent: Long audit", "running", tail: "Reading contracts\nmore"),
            ]),
            ask(),
            entry("a1", .assistant, at: 2, .streaming, [
                spawn("s2", "Agent: Refactor fee module", "running"),
                spawn("s3", "Agent: Summarize PRs", "done"),
                spawn("s4", "Agent: Broken", "failed"),
                spawn("s5", "Agent: Lost host", "disconnected"),
                spawn("s6", "Agent: Called off", "cancelled"),
            ]),
        ])
        XCTAssertEqual(work.agents.map(\.title),
                       ["Long audit", "Refactor fee module", "Summarize PRs", "Broken", "Lost host", "Called off"])
        XCTAssertEqual(work.agents.map(\.state), [.running, .running, .done, .failed, .failed, .stopped])
        XCTAssertEqual(work.agents.map(\.detail),
                       ["Reading contracts", "Working", "Ready to review", "Failed", "Failed", "Stopped"])
        XCTAssertTrue(AgentWork.agentsHeader(work) == ("2 agents", "running"))
        XCTAssertEqual(work.tools.first?.label, "Agents")
    }

    func testOnceNoAgentRunsTheHeaderCountsThemAllDone() {
        let spawn = tool("s", ["kind": "unknown", "name": "Agent: Audit"])
        var done = spawn
        done["subagentStatus"] = "done"
        let work = AgentWork.work([ask(), entry("a", .assistant, at: 1, .complete, [done])])
        XCTAssertTrue(AgentWork.agentsHeader(work) == ("1 agent", "done"))
        // A spawn chip without a lifecycle is not an agent row.
        XCTAssertTrue(AgentWork.work([ask(), entry("a", .assistant, at: 1, .complete, [spawn])]).agents.isEmpty)
    }

    func testSubstepsKeepTheNewestThree() {
        var parts = [todo("t", [("Work", false)])]
        for i in 0..<5 { parts.append(tool("r\(i)", ["kind": "readFile", "path": "f\(i).rs"])) }
        let work = AgentWork.work([ask(), entry("a", .assistant, at: 1, .streaming, parts)])
        XCTAssertEqual(work.steps[0].substeps.map(\.title), ["Read f2.rs", "Read f3.rs", "Read f4.rs"])
    }

    func testToolChipsDedupeInFirstUseOrder() {
        let work = AgentWork.work([
            ask(),
            entry("a", .assistant, at: 1, .complete, [
                tool("1", ["kind": "exec", "command": "make"]),
                tool("2", ["kind": "mcp", "server": "github", "tool": "list_prs"]),
                tool("3", ["kind": "exec", "command": "make test"]),
                tool("4", ["kind": "webSearch", "query": "fees"]),
                tool("5", ["kind": "unknown", "name": "Compact context"]),
            ]),
        ])
        XCTAssertEqual(work.tools.map(\.label), ["Terminal", "github", "Web"])
    }

    func testDurationsReadLikeTheDesign() {
        XCTAssertEqual(AgentWork.durationLabel(ms: 12_000), "12s")
        XCTAssertEqual(AgentWork.durationLabel(ms: 65_000), "1m 5s")
        XCTAssertEqual(AgentWork.durationLabel(ms: 120_000), "2m")
        XCTAssertEqual(AgentWork.durationLabel(ms: 3_780_000), "1h 3m")
    }

    func testTheChipSwitchesToACountPastSixSteps() {
        let step = AgentWork.Step(title: "", state: .done, durationMs: nil, status: nil, substeps: [])
        var work = AgentWork.Work(steps: Array(repeating: step, count: 6))
        XCTAssertEqual(AgentWork.chipDots(work)?.count, 6)
        work.steps.append(step)
        XCTAssertNil(AgentWork.chipDots(work))
        XCTAssertNil(AgentWork.chipDots(AgentWork.Work()))
    }

    func testSubagentTitlesDropTheGenusAndNeverAWorkerId() {
        func title(_ name: String) -> String? { AgentWork.subagentTitle(RenderToolCall(tag: "unknown", fields: ["name": name])) }
        XCTAssertEqual(title("Agent: scan repo"), "scan repo")
        XCTAssertEqual(title("Task: audit the auth flow"), "audit the auth flow")
        XCTAssertEqual(title("Taskmaster"), "Taskmaster")
        XCTAssertNil(title("Agent"))
        XCTAssertNil(title("Agent: 42"))
        XCTAssertNil(title("Agent: subagent"))
        XCTAssertTrue(RenderToolCall(tag: "unknown", fields: ["name": "Agent: scan repo"]).isSubagentSpawn)
        XCTAssertFalse(RenderToolCall(tag: "unknown", fields: ["name": "Agents"]).isSubagentSpawn)
    }
}
