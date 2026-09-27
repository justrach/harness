// Per-message memo for the transcript projection — the port of crates/doc
// `EntryCache` / `read_entries_cached`. A streaming update touches one
// message, so the projection re-decodes only the messages a doc event touched
// (plus ones it has never seen) instead of deep-reading the whole transcript
// on every update.

import Foundation
import Loro

final class EntryCache: @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by each message's map container. `nil` records a message that
    /// failed to parse (a torn import); it is retried only once it changes.
    private var entries: [ContainerId: MessageEntry?] = [:]
    private var stale: Set<ContainerId> = []

    /// Record which messages a doc event changed. Correct only while EVERY
    /// change under `messages` reaches here, so the owner subscribes before
    /// the doc is first loaded.
    func observe(_ event: DiffEvent) {
        var touched: [ContainerId] = []
        for diff in event.events {
            // path: [messages list, message map, …]. A change to the list
            // itself (insert/delete) needs no invalidation: new messages are
            // cache misses and removed ones drop out of the next read.
            guard diff.path.count >= 2, diff.path[0].index == .key(key: "messages") else { continue }
            touched.append(diff.path[1].container)
        }
        guard !touched.isEmpty else { return }
        lock.lock()
        stale.formUnion(touched)
        lock.unlock()
    }

    /// The doc's messages in list order, re-decoding only changed or unseen
    /// ones. Changes that land mid-read stay marked for the next read.
    func read(_ doc: LoroDoc, parse: (LoroValue) -> MessageEntry?) -> [MessageEntry] {
        lock.lock()
        let changed = stale
        stale = []
        let previous = entries
        lock.unlock()

        let (count, item) = Self.messages(in: doc)
        var next: [ContainerId: MessageEntry?] = [:]
        next.reserveCapacity(Int(count))
        var result: [MessageEntry] = []
        result.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let item = item(index) else { continue }
            if let id = item.asContainer(), let map = item.asLoroMap() {
                let entry: MessageEntry?
                if !changed.contains(id), let cached = previous[id] {
                    entry = cached
                } else {
                    entry = parse(map.getDeepValue())
                }
                next[id] = entry
                if let entry { result.append(entry) }
            } else if let value = item.asValue(), let entry = parse(value) {
                result.append(entry)
            }
        }

        lock.lock()
        entries = next
        lock.unlock()
        return result
    }

    /// The root `messages` container, whichever list type the writer used
    /// (hosts write a list; the whole-doc decode accepted either).
    private static func messages(in doc: LoroDoc) -> (UInt32, (UInt32) -> ValueOrContainer?) {
        guard case .container(let id)? = doc.getValue().mapValue?["messages"] else {
            return (0, { _ in nil })
        }
        if case .root(_, .movableList) = id {
            let list = doc.getMovableList(id: "messages")
            return (list.len(), { list.get(index: $0) })
        }
        let list = doc.getList(id: "messages")
        return (list.len(), { list.get(index: $0) })
    }
}
