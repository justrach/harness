// The iPhone end of the Apple Watch app (#322). The Watch hands over what
// was said; this keeps it in an inbox on disk, delivers each item once
// through the composer's own send path, and publishes the chat list and
// receipts back to the Watch.
//
// WatchConnectivity can launch the app in the background to hand an item
// over, before any window exists. The inbox survives that: an item waits
// until the account is restored, and a recording that needs the speech
// permission waits until Harness is opened.

import Foundation
import OSLog
import Speech
import UIKit
import WatchConnectivity

@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    /// Ids and outcomes only, never what was said.
    private let log = Logger(subsystem: "harness.codegraff.ios", category: "watch")

    private weak var model: AppModel?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var draining = false
    private var publishTask: Task<Void, Never>?
    private var lastPublished: WatchLink.Context?

    // MARK: Inbox (on disk)

    enum Item: Codable, Equatable {
        case dictation(WatchLink.Dictation)
        /// A recording to write out; its audio is `file` in the inbox folder.
        case recording(WatchLink.Recording, file: String)

        var id: String {
            switch self {
            case .dictation(let d): d.id
            case .recording(let r, _): r.id
            }
        }
    }

    struct Saved: Codable {
        var inbox: [Item] = []
        var seen = WatchLink.SeenIds()
        var receipts: [WatchLink.Receipt] = []
    }

    private var saved = Saved()
    private var loaded = false

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WatchInbox", isDirectory: true)
    }

    private static var savedURL: URL { folder.appendingPathComponent("inbox.json") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.savedURL),
              let decoded = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        saved = decoded
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.savedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Lifecycle

    /// At launch, before it finishes: WatchConnectivity delivers queued items
    /// as soon as the session is active.
    func activate() {
        guard let session else { return }
        load()
        session.delegate = self
        session.activate()
        drain()
    }

    /// The app's model, as soon as it exists (also on a background launch).
    func attach(_ model: AppModel) {
        self.model = model
        load()
        observeChats()
        drain()
    }

    /// The account came back (launch, sign-in) or the app came to the front.
    func modelReady() {
        drain()
        schedulePublish()
    }

    // MARK: Receiving

    /// Takes one item from the Watch: false when it was already taken.
    @discardableResult
    func receive(_ item: Item) -> Bool {
        load()
        guard saved.seen.insert(item.id) else { return false }
        saved.inbox.append(item)
        persist()
        drain()
        return true
    }

    private func handle(message: [String: Any]) -> [String: Any]? {
        switch WatchLink.kind(of: message) {
        case .dictation:
            guard let dictation = WatchLink.body(WatchLink.Dictation.self, of: message, as: .dictation) else { return nil }
            receive(.dictation(dictation))
            return ["accepted": dictation.id]
        case .hello:
            return WatchLink.message(.context, context())
        default:
            return nil
        }
    }

    // MARK: Delivering

    /// Delivers what can be delivered now, in order. Items that have to wait
    /// (no account yet, a recording without the speech permission) stay.
    func drain() {
        guard !draining, let model, !saved.inbox.isEmpty else { return }
        guard model.phase.isReady else {
            if UIApplication.shared.isProtectedDataAvailable, model.demo == nil, model.storedUserId.isEmpty {
                failAll("Sign in to Harness on your iPhone.")
            } else {
                // A background launch has no window to restore the account from.
                model.restore()
            }
            return
        }
        draining = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "Watch messages")
        Task { @MainActor in
            defer {
                draining = false
                model.flushDocs()
                UIApplication.shared.endBackgroundTask(background)
            }
            var waiting: [Item] = []
            for item in saved.inbox {
                switch await deliver(item, model: model) {
                case .done(let receipt):
                    if let receipt { saved.receipts = WatchLink.merged(saved.receipts, adding: receipt) }
                    if case .recording(_, let file) = item {
                        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(file))
                    }
                case .wait:
                    waiting.append(item)
                }
            }
            saved.inbox = waiting
            persist()
            publish()
        }
    }

    /// Nothing can be delivered (signed out): every item fails, with why.
    private func failAll(_ detail: String) {
        for item in saved.inbox {
            let chatId: String? = switch item {
            case .dictation(let d): d.chatId
            case .recording(let r, _): r.chatId
            }
            saved.receipts = WatchLink.merged(saved.receipts, adding: WatchLink.Receipt(
                id: item.id, state: .failed, chatId: chatId, detail: detail))
            if case .recording(_, let file) = item {
                try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(file))
            }
        }
        saved.inbox = []
        persist()
        publish()
    }

    private enum Outcome {
        /// Finished: delivered or failed for good (a transcript reply has no receipt).
        case done(WatchLink.Receipt?)
        case wait
    }

    private func deliver(_ item: Item, model: AppModel) async -> Outcome {
        switch item {
        case .dictation(let dictation):
            return .done(await send(dictation, model: model))
        case .recording(let recording, let file):
            let audio = Self.folder.appendingPathComponent(file)
            let result = await WatchTranscriber.transcribe(audio, appActive: UIApplication.shared.applicationState == .active)
            switch result {
            case .needsPermission:
                return .wait
            case .text(let text) where recording.deliver:
                let dictation = WatchLink.Dictation(id: recording.id, chatId: recording.chatId, text: text,
                                                    mode: recording.mode, createdAt: recording.createdAt)
                return .done(await send(dictation, model: model))
            case .text(let text):
                reply(.transcript, WatchLink.Transcript(id: recording.id, text: text, detail: nil))
                return .done(nil)
            case .failed(let detail) where recording.deliver:
                return .done(WatchLink.Receipt(id: recording.id, state: .failed, chatId: recording.chatId, detail: detail))
            case .failed(let detail):
                reply(.transcript, WatchLink.Transcript(id: recording.id, text: nil, detail: detail))
                return .done(nil)
            }
        }
    }

    /// The composer's send, for a chat the Watch picked or a new one.
    private func send(_ dictation: WatchLink.Dictation, model: AppModel) async -> WatchLink.Receipt {
        func failed(_ detail: String) -> WatchLink.Receipt {
            log.info("watch dictation \(dictation.id, privacy: .public) failed: \(detail, privacy: .public)")
            return WatchLink.Receipt(id: dictation.id, state: .failed, chatId: dictation.chatId, detail: detail)
        }
        guard let text = WatchLink.cleaned(dictation.text) else { return failed("There was nothing to send.") }
        let chat: Chat
        if let chatId = dictation.chatId {
            guard let existing = model.chat(id: chatId), !existing.archived else {
                return failed("That chat isn't on your iPhone any more.")
            }
            chat = existing
        } else {
            switch await model.startChatForWatch() {
            case .success(let created): chat = created
            case .failure(let reason): return failed(reason.sentence)
            }
        }
        guard let store = model.sessionStore(for: chat) else { return failed("Sign in to Harness on your iPhone.") }
        let indicator = model.indicator(for: chat)
        let runLive = indicator == .working || indicator == .awaitingInput
        let delivery = WatchLink.delivery(mode: dictation.mode, runLive: runLive,
                                          canQueue: model.hostSupportsMessageQueue(chat))
        switch delivery {
        case .run: store.sendRun(prompt: text, chat: chat)
        case .enqueue: store.enqueueMessage(text: text, holdForTurnEnd: true)
        case .steer: store.sendSteer(prompt: text)
        }
        log.info("watch dictation \(dictation.id, privacy: .public) delivered to \(chat.id, privacy: .public) as \(String(describing: delivery), privacy: .public)")
        return WatchLink.Receipt(id: dictation.id, state: .delivered, chatId: chat.id, detail: nil)
    }

    // MARK: Publishing

    private func observeChats() {
        guard let model else { return }
        withObservationTracking {
            _ = context(model: model)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePublish()
                self?.observeChats()
            }
        }
    }

    /// At most one update every couple of seconds while chats stream.
    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            publishTask = nil
            publish()
        }
    }

    private func context() -> WatchLink.Context {
        guard let model else { return WatchLink.Context(signedIn: false, chats: [], receipts: saved.receipts) }
        return context(model: model)
    }

    private func context(model: AppModel) -> WatchLink.Context {
        let chats = model.phase.isReady ? model.overviewChats.map { chat in
            WatchLink.ChatSummary(id: chat.id, title: chat.displayTitle,
                                  status: Self.status(model.indicator(for: chat)), calledAt: chat.calledAt)
        } : []
        return WatchLink.Context(signedIn: model.phase.isReady, chats: WatchLink.recent(chats),
                                 receipts: saved.receipts)
    }

    nonisolated static func status(_ indicator: ChatIndicator) -> WatchLink.Status {
        switch indicator {
        case .working: .working
        case .awaitingInput: .needsInput
        case .errored: .failed
        case .completed, .idle: .idle
        }
    }

    private func publish() {
        guard let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else {
            log.debug("watch context not published: no paired Watch with Harness installed")
            return
        }
        let context = context()
        guard context != lastPublished else { return }
        lastPublished = context
        log.info("watch context published: \(context.chats.count, privacy: .public) chats, signed in \(context.signedIn, privacy: .public)")
        try? session.updateApplicationContext(WatchLink.message(.context, context))
        if session.isReachable {
            // An open Watch app hears it now rather than on its next launch.
            session.sendMessage(WatchLink.message(.context, context), replyHandler: nil, errorHandler: nil)
        }
    }

    private func reply<T: Encodable>(_ kind: WatchLink.Kind, _ body: T) {
        guard let session, session.activationState == .activated else { return }
        let message = WatchLink.message(kind, body)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.schedulePublish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Another Watch was paired: talk to it instead.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.schedulePublish() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let message = SendableMessage(message)
        Task { @MainActor in _ = self.handle(message: message.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let message = SendableMessage(message)
        let reply = SendableReply(replyHandler)
        Task { @MainActor in reply.call(self.handle(message: message.value) ?? [:]) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let message = SendableMessage(userInfo)
        Task { @MainActor in _ = self.handle(message: message.value) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this returns: move it into the inbox first.
        guard let metadata = file.metadata,
              let recording = WatchLink.body(WatchLink.Recording.self, of: metadata, as: .recording) else { return }
        let name = "\(recording.id).\(file.fileURL.pathExtension.isEmpty ? "m4a" : file.fileURL.pathExtension)"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: file.fileURL, to: target)) != nil else { return }
        Task { @MainActor in self.receive(.recording(recording, file: name)) }
    }
}

/// WatchConnectivity's dictionaries are property lists, safe to hand across.
private struct SendableMessage: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

private struct SendableReply: @unchecked Sendable {
    let call: ([String: Any]) -> Void
    init(_ call: @escaping ([String: Any]) -> Void) { self.call = call }
}

// MARK: Transcribing recordings

enum WatchTranscriber {
    enum Result: Equatable {
        case text(String)
        /// Speech recognition isn't allowed yet; asking needs the app open.
        case needsPermission
        case failed(String)
    }

    static func transcribe(_ audio: URL, appActive: Bool) async -> Result {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            guard appActive else { return .needsPermission }
            status = await withCheckedContinuation { done in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            return .failed("Allow speech recognition for Harness in the iPhone's Settings.")
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            return .failed("Speech recognition isn't available on your iPhone right now.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        // Nothing leaves the phone when it can recognize on its own.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let text: String? = await withCheckedContinuation { done in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    done.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    finished = true
                    done.resume(returning: nil)
                }
            }
        }
        guard let text, let cleaned = WatchLink.cleaned(text) else {
            return .failed("Couldn't make out any words in the recording.")
        }
        return .text(cleaned)
    }
}
