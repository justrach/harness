import XCTest
@testable import Harness

final class SessionCompanionsTests: XCTestCase {
    private func makeChat(
        id: String,
        parentChatId: String? = nil,
        archived: Bool = false
    ) -> Chat {
        Chat(
            id: id,
            deviceId: "dev-mac",
            title: id,
            archived: archived,
            cwd: "/Users/dev/harness",
            branch: "main",
            checkoutId: nil,
            config: ChatConfig(harness: "claude-code"),
            lastMessagePreview: nil,
            lastMessageAt: 1_000,
            createdAt: 1_000,
            spaceId: "space-1",
            lastSeenAt: 1_000,
            roomGen: 2,
            lastPromptAt: nil,
            parentChatId: parentChatId
        )
    }

    private func makeSubagentEntry(
        id: String,
        name: String,
        status: String?,
        resolved: Bool = true,
        tail: String? = nil
    ) -> MessageEntry {
        var fields: [String: AnyHashable] = ["name": name]
        if let status { fields[RenderToolCall.subagentStatusKey] = status }
        if let tail { fields[RenderToolCall.subagentTailKey] = tail }
        return MessageEntry(
            id: id,
            role: .assistant,
            parts: [.tool(id: "\(id)-call", call: RenderToolCall(tag: "unknown", fields: fields), isError: false, resolved: resolved)],
            createdAt: 1_000,
            deviceId: "dev-mac",
            status: resolved ? .complete : .streaming
        )
    }

    // MARK: - CompanionStripState

    func testCompanionStripStateEmptyWhenNoCompanions() {
        let parent = makeChat(id: "chat-1")
        let unrelated = makeChat(id: "chat-2")
        let otherTerminal = HostTerminalSessionInfo(
            id: "t-other", chatId: "chat-2", deviceId: "dev-mac",
            cwd: "/tmp", shell: "zsh", exited: false, exitCode: nil, signal: nil, lastSeq: 0
        )

        let state = CompanionStripState.resolve(
            chat: parent,
            allChats: [parent, unrelated],
            entries: [],
            terminals: [otherTerminal]
        )

        XCTAssertEqual(state, CompanionStripState(subagents: 0, runningSubagents: 0, sideChats: 0, terminals: 0, liveTerminals: 0))
        XCTAssertTrue(state.isEmpty)
    }

    func testCompanionStripStateResolvesSubagentsSideChatsAndTerminals() {
        let parent = makeChat(id: "parent")
        let sideA = makeChat(id: "side-a", parentChatId: "parent")
        let sideB = makeChat(id: "side-b", parentChatId: "parent")
        let archivedSide = makeChat(id: "side-archived", parentChatId: "parent", archived: true)
        let grandchild = makeChat(id: "grandchild", parentChatId: "side-a")

        let entries = [
            makeSubagentEntry(id: "e1", name: "Agent: scan repo", status: "running", resolved: false, tail: "Reading Package.swift"),
            makeSubagentEntry(id: "e2", name: "Agent: run tests", status: "done", resolved: true),
            makeSubagentEntry(id: "e3", name: "Agent: check lint", status: nil, resolved: false),
        ]

        let terminals = [
            HostTerminalSessionInfo(id: "t1", chatId: "parent", deviceId: "dev-mac", cwd: "/repo", shell: "zsh", exited: false, exitCode: nil, signal: nil, lastSeq: 3),
            HostTerminalSessionInfo(id: "t2", chatId: "parent", deviceId: "dev-mac", cwd: "/repo", shell: "bash", exited: true, exitCode: 0, signal: nil, lastSeq: 9),
            HostTerminalSessionInfo(id: "t3", chatId: "side-a", deviceId: "dev-mac", cwd: "/repo", shell: "zsh", exited: false, exitCode: nil, signal: nil, lastSeq: 1),
        ]

        let state = CompanionStripState.resolve(
            chat: parent,
            allChats: [parent, sideA, sideB, archivedSide, grandchild],
            entries: entries,
            terminals: terminals
        )

        XCTAssertEqual(state.subagents, 3)
        XCTAssertEqual(state.runningSubagents, 2)
        XCTAssertEqual(state.sideChats, 2)
        XCTAssertEqual(state.terminals, 2)
        XCTAssertEqual(state.liveTerminals, 1)
        XCTAssertFalse(state.isEmpty)
    }

    // MARK: - TerminalScreenBuffer

    func testScreenBufferSgrColorsAndAttributes() {
        let buffer = TerminalScreenBuffer(cols: 40, rows: 10)
        buffer.feed("\u{1B}[1;31;44mRed\u{1B}[0m \u{1B}[38;5;196m256\u{1B}[0m \u{1B}[38;2;12;34;56;48;2;200;150;100mTC")

        let rCell = buffer.cellAt(row: 0, col: 0)
        XCTAssertEqual(rCell.scalar, "R")
        XCTAssertTrue(rCell.attributes.bold)
        XCTAssertEqual(rCell.attributes.foreground, .ansi(1))
        XCTAssertEqual(rCell.attributes.background, .ansi(4))

        let spaceCell = buffer.cellAt(row: 0, col: 3)
        XCTAssertEqual(spaceCell.scalar, " ")
        XCTAssertEqual(spaceCell.attributes, .default)

        let idxCell = buffer.cellAt(row: 0, col: 4)
        XCTAssertEqual(idxCell.scalar, "2")
        XCTAssertEqual(idxCell.attributes.foreground, .indexed(196))

        let tcCell = buffer.cellAt(row: 0, col: 8)
        XCTAssertEqual(tcCell.scalar, "T")
        XCTAssertEqual(tcCell.attributes.foreground, .rgb(12, 34, 56))
        XCTAssertEqual(tcCell.attributes.background, .rgb(200, 150, 100))
    }

    func testScreenBufferCursorMovesAndClearSequences() {
        let buffer = TerminalScreenBuffer(cols: 20, rows: 5)
        buffer.feed("hello world\r\nsecond line")
        buffer.feed("\u{1B}[1;7HXYZ") // row 1 col 7 (1-based) -> "hello XYZld"
        XCTAssertEqual(buffer.lineText(row: 0), "hello XYZld")

        buffer.feed("\u{1B}[1;6H\u{1B}[K") // erase to EOL from col 5 -> "hello"
        XCTAssertEqual(buffer.lineText(row: 0), "hello")

        buffer.feed("\u{1B}[2;1H\u{1B}[2K") // erase entire line 2
        XCTAssertEqual(buffer.lineText(row: 1), "")

        buffer.feed("\u{1B}[2J\u{1B}[Htop")
        XCTAssertEqual(buffer.plainText(), "top")
    }

    func testScreenBufferBackspaceScrollbackAndAltScreen() {
        let buffer = TerminalScreenBuffer(cols: 20, rows: 3, maxScrollback: 50)
        buffer.feed("ab\u{08}c\r\nline2\r\nline3\r\nline4")

        XCTAssertEqual(buffer.scrollback.count, 1)
        XCTAssertEqual(buffer.lineText(row: 0), "line2")
        XCTAssertEqual(buffer.lineText(row: 1), "line3")
        XCTAssertEqual(buffer.lineText(row: 2), "line4")

        let firstScroll = String(buffer.scrollback[0].prefix(2).map { Character($0.scalar) })
        XCTAssertEqual(firstScroll, "ac")

        buffer.feed("\u{1B}[?1049h\u{1B}[Halt")
        XCTAssertTrue(buffer.isAlternateScreen)
        XCTAssertEqual(buffer.lineText(row: 0), "alt")

        buffer.feed("\u{1B}[?1049l")
        XCTAssertFalse(buffer.isAlternateScreen)
        XCTAssertEqual(buffer.lineText(row: 0), "line2")
    }

    func testScreenBufferSplitUtf8AndGlyphClassification() {
        let buffer = TerminalScreenBuffer(cols: 20, rows: 4)
        let utf8Bytes = Array("┌─█─┐".utf8)
        buffer.feed(Data(utf8Bytes.prefix(4)))
        buffer.feed(Data(utf8Bytes.dropFirst(4)))
        XCTAssertEqual(buffer.lineText(row: 0), "┌─█─┐")

        XCTAssertEqual(TerminalGlyphKind.classify("┌"), .boxDrawing)
        XCTAssertEqual(TerminalGlyphKind.classify("─"), .boxDrawing)
        XCTAssertEqual(TerminalGlyphKind.classify("╭"), .boxDrawing)
        XCTAssertEqual(TerminalGlyphKind.classify("█"), .blockElement)
        XCTAssertEqual(TerminalGlyphKind.classify("▓"), .blockElement)
        XCTAssertEqual(TerminalGlyphKind.classify("▀"), .blockElement)
        XCTAssertEqual(TerminalGlyphKind.classify("A"), .text)
        XCTAssertEqual(TerminalGlyphKind.classify(" "), .text)
    }

    func testTerminalInputEncoderStickyCtrl() {
        let ctrlC = TerminalInputEncoder.encode(text: "c", ctrl: true)
        XCTAssertEqual(ctrlC.data, Data([0x03]))
        XCTAssertTrue(ctrlC.consumedCtrl)

        let enter = TerminalInputEncoder.encode(text: "\n", ctrl: false)
        XCTAssertEqual(enter.data, Data([0x0D]))
        XCTAssertFalse(enter.consumedCtrl)
    }

    // MARK: - Terminal RPC JSON Wire Schema

    func testTerminalRpcJsonWireSchema() throws {
        // TerminalSession reply from crates/proto/src/entities.rs
        let sessionJson = #"{"id":"term-123","cwd":"/Users/dev/harness","shell":"zsh"}"#
        let session = try JSONDecoder().decode(TerminalSessionWire.self, from: Data(sessionJson.utf8))
        XCTAssertEqual(session, TerminalSessionWire(id: "term-123", cwd: "/Users/dev/harness", shell: "zsh"))

        // TerminalEvent::Data (tagged "type": "data", base64 payload)
        let dataEventJson = #"{"type":"data","seq":7,"data":"aGVsbG8K"}"#
        let dataEvent = try JSONDecoder().decode(TerminalEventWire.self, from: Data(dataEventJson.utf8))
        XCTAssertEqual(dataEvent, .data(seq: 7, data: "aGVsbG8K"))
        XCTAssertEqual(String(data: try XCTUnwrap(dataEvent.decodedBytes), encoding: .utf8), "hello\n")

        // TerminalEvent::Exit with and without optional signal
        let exitNoSigJson = #"{"type":"exit","seq":8,"exitCode":0}"#
        let exitNoSig = try JSONDecoder().decode(TerminalEventWire.self, from: Data(exitNoSigJson.utf8))
        XCTAssertEqual(exitNoSig, .exit(seq: 8, exitCode: 0, signal: nil))

        let exitWithSigJson = #"{"type":"exit","seq":9,"exitCode":143,"signal":"SIGTERM"}"#
        let exitWithSig = try JSONDecoder().decode(TerminalEventWire.self, from: Data(exitWithSigJson.utf8))
        XCTAssertEqual(exitWithSig, .exit(seq: 9, exitCode: 143, signal: "SIGTERM"))

        // Request parameter encoding (camelCase + base64 WriteTerminal)
        let writeParams = WriteTerminalParams(terminalId: "term-123", rawBytes: Data([0x03]))
        let writeData = try JSONEncoder().encode(writeParams)
        let writeObj = try XCTUnwrap(try JSONSerialization.jsonObject(with: writeData) as? [String: Any])
        XCTAssertEqual(writeObj["terminalId"] as? String, "term-123")
        XCTAssertEqual(writeObj["data"] as? String, "Aw==")

        let openParams = OpenTerminalParams(chatId: "chat-1", cols: 80, rows: 24, cwd: "/repo")
        let openDict = openParams.toDictionary()
        XCTAssertEqual(openDict["chatId"] as? String, "chat-1")
        XCTAssertEqual(openDict["cols"] as? Int, 80)
        XCTAssertEqual(openDict["rows"] as? Int, 24)
        XCTAssertEqual(openDict["cwd"] as? String, "/repo")

        let subParams = SubscribeTerminalParams(terminalId: "term-123", afterSeq: 7)
        let subDict = subParams.toDictionary()
        XCTAssertEqual(subDict["terminalId"] as? String, "term-123")
        XCTAssertEqual(subDict["afterSeq"] as? UInt64, 7)

        let resizeParams = ResizeTerminalParams(terminalId: "term-123", cols: 120, rows: 40)
        let resizeDict = resizeParams.toDictionary()
        XCTAssertEqual(resizeDict["terminalId"] as? String, "term-123")
        XCTAssertEqual(resizeDict["cols"] as? Int, 120)
        XCTAssertEqual(resizeDict["rows"] as? Int, 40)

        let closeParams = CloseTerminalParams(terminalId: "term-123")
        XCTAssertEqual(closeParams.toDictionary()["terminalId"] as? String, "term-123")
    }
}
