// The Watch app's state and its link to the iPhone (#322). The Watch records
// and transcribes; the iPhone delivers. Each dictation carries an id made
// here, so whichever way WatchConnectivity hands it over (a message while
// the iPhone is reachable, queued user info while it isn't), it's sent once.

import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    /// The iPhone's latest chat list and receipts (kept across launches).
    private(set) var context: WatchLink.Context?
    private(set) var sent: [WatchLink.Sent] = []
    private(set) var reachable = false
    /// Which chat the next message goes to.
    var target: Target = .latest { didSet { save() } }
    /// How a message joins a chat whose agent is working.
    var mode: WatchLink.Mode = .queue { didSet { save() } }
    /// Transcripts the iPhone sent back for review, by recording id.
    private(set) var transcripts: [String: WatchLink.Transcript] = [:]
    /// Dictations the iPhone hasn't confirmed. Queued user info can take a
    /// while to cross, so each is also sent directly whenever the iPhone is
    /// reachable; the iPhone delivers an id once.
    @ObservationIgnored private var outbox: [WatchLink.Dictation] = []

    enum Target: Codable, Equatable {
        /// The most recently called chat (a new chat when there's none).
        case latest
        case chat(String)
        case newChat
    }

    private let defaults = UserDefaults.standard
    @ObservationIgnored private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    override init() {
        super.init()
        load()
        if ProcessInfo.processInfo.arguments.contains("-watchDemo") { seedDemo() }
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: Target

    var chats: [WatchLink.ChatSummary] { WatchLink.recent(context?.chats ?? []) }

    /// The chat a message goes to now; `nil` is a new chat.
    var targetChat: WatchLink.ChatSummary? {
        switch target {
        case .latest: chats.first
        case .chat(let id): chats.first { $0.id == id } ?? chats.first
        case .newChat: nil
        }
    }

    var targetTitle: String { targetChat?.title ?? "New chat" }

    /// Whether the mode choice matters: the target's agent is working.
    var targetBusy: Bool {
        guard let status = targetChat?.status else { return false }
        return status == .working || status == .needsInput
    }

    // MARK: Sending

    /// Sends `text` to the target chat. False when there's nothing to send.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard let text = WatchLink.cleaned(text) else { return false }
        let chat = targetChat
        let dictation = WatchLink.Dictation(id: Self.newId(), chatId: chat?.id, text: text, mode: mode,
                                            createdAt: Self.nowMs())
        outbox.append(dictation)
        record(WatchLink.Sent(id: dictation.id, text: text, chatTitle: chat?.title ?? "New chat",
                              state: .waiting, createdAt: dictation.createdAt))
        deliver(WatchLink.message(.dictation, dictation))
        return true
    }

    /// A recording the iPhone writes out. `deliver`: send it as a message
    /// (the iPhone is away); otherwise only get its text back for review.
    func sendRecording(_ file: URL, id: String, deliver: Bool) {
        guard let session else { return }
        let chat = targetChat
        let recording = WatchLink.Recording(id: id, chatId: chat?.id, mode: mode, createdAt: Self.nowMs(),
                                            deliver: deliver)
        if deliver {
            record(WatchLink.Sent(id: id, text: "Recording", chatTitle: chat?.title ?? "New chat",
                                  state: .waiting, createdAt: recording.createdAt))
        }
        session.transferFile(file, metadata: WatchLink.message(.recording, recording))
    }

    /// Asks the iPhone for a fresh chat list.
    func refresh() {
        guard let session, session.isReachable else { return }
        session.sendMessage(WatchLink.hello(), replyHandler: { reply in
            let reply = Reply(reply)
            Task { @MainActor in self.take(reply.value) }
        }, errorHandler: nil)
    }

    /// Sends what the iPhone hasn't confirmed, now that it's reachable.
    private func flushOutbox() {
        // A day without a receipt: the iPhone has it or never will.
        outbox.removeAll { Self.nowMs() - $0.createdAt > 86_400_000 }
        guard let session, session.isReachable else { return }
        for dictation in outbox {
            session.sendMessage(WatchLink.message(.dictation, dictation), replyHandler: nil, errorHandler: nil)
        }
    }

    private func deliver(_ message: [String: Any]) {
        guard let session else { return }
        let fallback = Reply(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                // Not taken now: queue it. The iPhone delivers an id once.
                session.transferUserInfo(fallback.value)
            }
        } else {
            session.transferUserInfo(message)
        }
    }

    private func record(_ row: WatchLink.Sent) {
        sent = Array(([row] + sent).prefix(WatchLink.sentLimit))
        save()
    }

    func forgetTranscript(_ id: String) {
        transcripts[id] = nil
    }

    // MARK: Receiving

    private func take(_ message: [String: Any]) {
        if let context = WatchLink.body(WatchLink.Context.self, of: message, as: .context) {
            self.context = context
            let before = sent
            sent = WatchLink.applying(context.receipts, to: sent)
            // A tap on the wrist when a message lands, or doesn't.
            if let changed = zip(before, sent).first(where: { $0.state != $1.state })?.1 {
                switch changed.state {
                case .delivered: WatchTheme.haptic(.success)
                case .failed: WatchTheme.haptic(.failure)
                case .waiting: break
                }
            }
            let settled = Set(context.receipts.map(\.id))
            outbox.removeAll { settled.contains($0.id) }
            save()
            autosendOnce()
        } else if let transcript = WatchLink.body(WatchLink.Transcript.self, of: message, as: .transcript) {
            transcripts[transcript.id] = transcript
        }
    }

    // MARK: Saved state

    private struct Saved: Codable {
        var context: WatchLink.Context?
        var sent: [WatchLink.Sent]
        var target: Target
        var mode: WatchLink.Mode
        var outbox: [WatchLink.Dictation]?
    }

    private func load() {
        guard let data = defaults.data(forKey: "watch.state"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        context = saved.context
        sent = saved.sent
        target = saved.target
        mode = saved.mode
        outbox = saved.outbox ?? []
    }

    private func save() {
        let saved = Saved(context: context, sent: sent, target: target, mode: mode, outbox: outbox)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "watch.state") }
    }

    /// Simulator rig: `-watchAutosend <text>` sends once the iPhone's chat
    /// list arrives, so the round trip can be driven without a finger.
    @ObservationIgnored private var autosent = false

    private func autosendOnce() {
        let args = ProcessInfo.processInfo.arguments
        guard !autosent, let ix = args.firstIndex(of: "-watchAutosend"), ix + 1 < args.count else { return }
        autosent = true
        send(args[ix + 1])
    }

    /// Screenshot rig: `-watchScreen picker|review|recording` opens that screen.
    static let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let ix = args.firstIndex(of: "-watchScreen"), ix + 1 < args.count else { return nil }
        return args[ix + 1]
    }()

    static func newId() -> String { UUID().uuidString.lowercased() }
    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Screenshots and the simulator: made-up chats, no iPhone needed.
    private func seedDemo() {
        let now = Self.nowMs()
        context = WatchLink.Context(signedIn: true, chats: [
            .init(id: "demo-1", title: "Fix the flaky upload test", status: .working, calledAt: now - 60_000),
            .init(id: "demo-2", title: "Release notes for 2.4", status: .idle, calledAt: now - 3_600_000),
            .init(id: "demo-3", title: "Plan the settings page", status: .needsInput, calledAt: now - 7_200_000),
        ], receipts: [])
        sent = [
            WatchLink.Sent(id: "demo-sent", text: "Also check the retry path when the upload times out",
                           chatTitle: "Fix the flaky upload test", state: .delivered, createdAt: now - 30_000),
            WatchLink.Sent(id: "demo-older", text: "Keep the settings page to one column on phones",
                           chatTitle: "Plan the settings page", state: .delivered, createdAt: now - 3_600_000),
        ]
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = Reply(session.receivedApplicationContext)
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if !context.value.isEmpty { self.take(context.value) }
            self.refresh()
            self.flushOutbox()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable {
                self.refresh()
                self.flushOutbox()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let message = Reply(applicationContext)
        Task { @MainActor in self.take(message.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let message = Reply(message)
        Task { @MainActor in self.take(message.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let message = Reply(userInfo)
        Task { @MainActor in self.take(message.value) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // The recording reached the iPhone (or never will): drop the local copy.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}

/// WatchConnectivity's dictionaries are property lists, safe to hand across.
private struct Reply: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
