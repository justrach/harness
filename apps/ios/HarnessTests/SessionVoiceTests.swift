import XCTest
@testable import Harness

final class SessionVoiceTests: XCTestCase {
    func testVoicePhaseMapsToLiveActivityVoiceState() {
        XCTAssertNil(SessionVoiceRules.liveActivityState(for: .idle, runLive: false))
        XCTAssertNil(SessionVoiceRules.liveActivityState(for: .requestingPermission, runLive: false))
        XCTAssertNil(SessionVoiceRules.liveActivityState(for: .error("denied"), runLive: false))
        XCTAssertEqual(SessionVoiceRules.liveActivityState(for: .listening(transcript: "hi"), runLive: false), .listening)
        XCTAssertEqual(SessionVoiceRules.liveActivityState(for: .listening(transcript: ""), runLive: true), .processing)
        XCTAssertEqual(SessionVoiceRules.liveActivityState(for: .processing(prompt: "run tests"), runLive: true), .processing)
        XCTAssertEqual(SessionVoiceRules.liveActivityState(for: .speaking(reply: "All green."), runLive: false), .speaking)
        XCTAssertEqual(SessionVoiceRules.liveActivityState(for: .muted, runLive: false), .muted)
    }

    func testSilenceEndpointingRequiresNonEmptyTextAndThreshold() {
        XCTAssertFalse(SessionVoiceRules.shouldAutoSend(transcript: "   ", silenceElapsedMs: 5_000))
        XCTAssertFalse(SessionVoiceRules.shouldAutoSend(transcript: "Run cargo test", silenceElapsedMs: 900))
        XCTAssertTrue(SessionVoiceRules.shouldAutoSend(transcript: "Run cargo test", silenceElapsedMs: 1_400))
    }

    func testExtractSpeakableReplyStripsCodeFencesAndIgnoresStreamingOrEarlierEntries() {
        let entries: [MessageEntry] = [
            MessageEntry(
                id: "baseline",
                role: .assistant,
                parts: [.text(id: "t0", text: "Earlier reply")],
                createdAt: 1,
                deviceId: "mac",
                status: .complete
            ),
            MessageEntry(
                id: "u1",
                role: .user,
                parts: [.text(id: "t1", text: "Fix the header")],
                createdAt: 2,
                deviceId: "phone",
                status: .complete
            ),
            MessageEntry(
                id: "a1-streaming",
                role: .assistant,
                parts: [.text(id: "t2", text: "Still streaming")],
                createdAt: 3,
                deviceId: "mac",
                status: .streaming
            ),
        ]
        XCTAssertNil(SessionVoiceRules.extractSpeakableReply(from: entries, afterEntryId: "baseline"))

        let settled = entries + [
            MessageEntry(
                id: "a2-settled",
                role: .assistant,
                parts: [.text(id: "t3", text: "## Summary\nUpdated **SessionView** cleanly.\n```swift\nlet x = 1\n```\nTests passed.")],
                createdAt: 4,
                deviceId: "mac",
                status: .complete
            )
        ]
        let reply = SessionVoiceRules.extractSpeakableReply(from: settled, afterEntryId: "baseline")
        XCTAssertEqual(reply?.entryId, "a2-settled")
        XCTAssertEqual(reply?.text, "Summary Updated SessionView cleanly. Code block omitted. Tests passed.")
    }

    func testActiveVoiceModeStartsAndUpdatesLiveActivityEvenWhenChatIsIdle() {
        let attrs = SessionActivityAttributes(
            chatId: "voice-chat",
            title: "Voice architecture review",
            project: "harness",
            device: "MacBook Pro",
            projectTint: 0,
            harness: "claude-code"
        )
        let snap = LiveActivitySnapshot(
            attributes: attrs,
            phase: nil,
            startedAt: Date(timeIntervalSince1970: 100),
            detail: "Listening…",
            tasks: nil,
            voiceState: .listening
        )
        XCTAssertEqual(snap.state?.phase, .working)
        XCTAssertEqual(snap.state?.voiceState, .listening)
        XCTAssertEqual(LiveActivityPlan.steps(showing: [:], sessions: [snap]), [.start(chatId: "voice-chat")])

        var speakingSnap = snap
        speakingSnap.voiceState = .speaking
        speakingSnap.detail = "All tests passed."
        let shown = ["voice-chat": snap.state!]
        XCTAssertEqual(LiveActivityPlan.steps(showing: shown, sessions: [speakingSnap]), [.update(chatId: "voice-chat")])
    }
}
