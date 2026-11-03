// The Apple Watch ↔ iPhone contract (#322). Compiled into the iPhone app,
// the Watch app and the Watch complication, so both ends read and write the
// same shapes. Everything travels over WatchConnectivity as a property list:
// a `kind` and a JSON `body`.
//
// The Watch only records and transcribes. The iPhone turns each dictation
// into the composer's own send (a run, a queued message or a steer), so it
// lands in the transcript and syncs to every other device like any message.

import Foundation

enum WatchLink {
    /// Opens the Watch app straight into recording (the complication's link).
    static let dictateURL = URL(string: "harness-watch://dictate")!

    // MARK: Payloads

    /// How a dictation joins a chat whose agent is working. A chat at rest
    /// starts a turn either way.
    enum Mode: String, Codable, CaseIterable {
        /// Wait for the current turn to end (the composer's default).
        case queue
        /// Steer the turn that's running.
        case now
    }

    struct Dictation: Codable, Equatable, Identifiable {
        /// Made on the Watch. The iPhone delivers each id once, however
        /// many times WatchConnectivity hands it over.
        var id: String
        /// `nil` starts a new chat.
        var chatId: String?
        var text: String
        var mode: Mode
        var createdAt: Int64
    }

    /// Audio the Watch couldn't turn into text itself. The iPhone transcribes
    /// it on the device.
    struct Recording: Codable, Equatable, Identifiable {
        var id: String
        var chatId: String?
        var mode: Mode
        var createdAt: Int64
        /// Send the text as a message (recorded while the iPhone was away).
        /// Otherwise only reply with the text, for review on the Watch.
        var deliver: Bool
    }

    /// The iPhone's answer to a `Recording` that isn't delivered.
    struct Transcript: Codable, Equatable {
        var id: String
        var text: String?
        /// Why there's no text.
        var detail: String?
    }

    enum Status: String, Codable {
        case working, needsInput, failed, idle

        var label: String {
            switch self {
            case .working: "Working"
            case .needsInput: "Needs input"
            case .failed: "Failed"
            case .idle: "Idle"
            }
        }
    }

    struct ChatSummary: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var status: Status
        /// When someone last prompted it (`Chat.calledAt`): the list's order.
        var calledAt: Int64
    }

    struct Receipt: Codable, Equatable {
        enum State: String, Codable { case delivered, failed }
        var id: String
        var state: State
        /// The chat it went to (a new chat's id once it exists).
        var chatId: String?
        /// Why it failed, in a sentence.
        var detail: String?
    }

    /// What the iPhone publishes: the latest wins.
    struct Context: Codable, Equatable {
        var signedIn: Bool
        var chats: [ChatSummary]
        var receipts: [Receipt]
    }

    // MARK: Envelope

    enum Kind: String {
        case dictation, recording, transcript, context
        /// The Watch asking for a fresh `Context`.
        case hello
    }

    static func message<T: Encodable>(_ kind: Kind, _ body: T) -> [String: Any] {
        let data = (try? JSONEncoder().encode(body)) ?? Data()
        return ["kind": kind.rawValue, "body": data]
    }

    static func hello() -> [String: Any] { ["kind": Kind.hello.rawValue] }

    static func kind(of message: [String: Any]) -> Kind? {
        (message["kind"] as? String).flatMap(Kind.init(rawValue:))
    }

    static func body<T: Decodable>(_ type: T.Type, of message: [String: Any], as kind: Kind) -> T? {
        guard self.kind(of: message) == kind, let data = message["body"] as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Rules

    /// What the iPhone does with a dictation for an existing chat.
    enum Delivery: Equatable {
        /// Start a turn (nothing is running).
        case run
        /// Add it to the chat's queue, delivered when the turn ends.
        case enqueue
        /// Into the running turn.
        case steer
    }

    /// A chat at rest starts a turn. While one runs, `queue` waits in the
    /// shared queue (a host too old for it gets a steer, so the words still
    /// land) and `now` steers.
    static func delivery(mode: Mode, runLive: Bool, canQueue: Bool) -> Delivery {
        guard runLive else { return .run }
        switch mode {
        case .queue: return canQueue ? .enqueue : .steer
        case .now: return .steer
        }
    }

    /// Dictated text as sent: trimmed, and nothing at all if only whitespace.
    static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How many chats the Watch lists.
    static let recentLimit = 8

    /// The Watch's chat list: most recently called first.
    static func recent(_ chats: [ChatSummary]) -> [ChatSummary] {
        Array(chats.sorted { $0.calledAt > $1.calledAt }.prefix(recentLimit))
    }

    /// Receipts the iPhone keeps publishing, so a Watch that was away still
    /// learns how its messages went.
    static let receiptLimit = 40

    /// `receipts` with `new` as the latest: replaces one for the same id.
    static func merged(_ receipts: [Receipt], adding new: Receipt) -> [Receipt] {
        Array((receipts.filter { $0.id != new.id } + [new]).suffix(receiptLimit))
    }

    /// The ids a receiver has already taken, so a dictation handed over
    /// twice (a message whose reply was lost, then the same item as user
    /// info) is delivered once.
    struct SeenIds: Codable, Equatable {
        static let limit = 200
        private(set) var ids: [String] = []

        /// False when `id` was already seen.
        mutating func insert(_ id: String) -> Bool {
            guard !ids.contains(id) else { return false }
            ids.append(id)
            if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
            return true
        }
    }

    // MARK: The Watch's outbox

    struct Sent: Codable, Equatable, Identifiable {
        enum State: Codable, Equatable {
            /// Handed to WatchConnectivity; the iPhone hasn't answered yet.
            case waiting
            case delivered
            case failed(String)
        }

        var id: String
        /// What the row shows: the text, or "Recording" before it's written out.
        var text: String
        var chatTitle: String
        var state: State
        var createdAt: Int64
    }

    /// How many sent messages the Watch remembers.
    static let sentLimit = 20

    /// `sent` updated from the iPhone's receipts. A receipt never moves a
    /// row backwards: a delivered row stays delivered.
    static func applying(_ receipts: [Receipt], to sent: [Sent]) -> [Sent] {
        sent.map { row in
            guard row.state != .delivered, let receipt = receipts.last(where: { $0.id == row.id }) else {
                return row
            }
            var row = row
            switch receipt.state {
            case .delivered: row.state = .delivered
            case .failed: row.state = .failed(receipt.detail ?? "Couldn't send")
            }
            return row
        }
    }
}
