// Unsent composer text, kept per chat and per new-session destination so leaving a
// screen never costs someone the message they were writing. It lives on disk, so
// it also survives the app being closed, except in demo mode, where nothing a demo
// person types is written out. Signing out wipes every draft.

import Foundation

@MainActor
enum DraftStore {
    private static let prefix = "draft."
    private static var memory: [String: String] = [:]

    /// False in demo mode: drafts survive navigation but never reach disk.
    static var persistsToDisk = true

    static func chatKey(_ chatId: String) -> String { "chat:\(chatId)" }

    static func newSessionKey(_ destination: NewSessionDestination) -> String {
        "new:\(destination.draftKey)"
    }

    static func load(_ key: String) -> String {
        if let value = memory[key] { return value }
        guard persistsToDisk else { return "" }
        return UserDefaults.standard.string(forKey: prefix + key) ?? ""
    }

    /// A draft that is only whitespace is no draft: the key is dropped.
    static func save(_ text: String, for key: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            memory[key] = nil
            if persistsToDisk { UserDefaults.standard.removeObject(forKey: prefix + key) }
            return
        }
        memory[key] = text
        if persistsToDisk { UserDefaults.standard.set(text, forKey: prefix + key) }
    }

    static func wipeAll() {
        memory.removeAll()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
