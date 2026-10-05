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
    /// Keyed by each PART map container inside a message — a streaming
    /// message with hundreds of parts re-decodes only the parts its update
    /// actually touched, not the whole deep value.
    private var partCache: [ContainerId: MessagePart?] = [:]
    private var stale: Set<ContainerId> = []
    private var staleParts: Set<ContainerId> = []

    /// Record which messages a doc event changed. Correct only while EVERY
    /// change under `messages` reaches here, so the owner subscribes before
    /// the doc is first loaded.
    func observe(_ event: DiffEvent) {
        var touched: [ContainerId] = []
        var touchedParts: [ContainerId] = []
        for diff in event.events {
            // path: [messages list, message map, parts list, part map, …].
            // A change to the list itself (insert/delete) needs no
            // invalidation: new messages are cache misses and removed ones
            // drop out of the next read.
            guard diff.path.count >= 2, diff.path[0].index == .key(key: "messages") else { continue }
            touched.append(diff.path[1].container)
            // A change at or below a part map (e.g. the streaming text field)
            // invalidates that part's decode alone.
            if diff.path.count >= 4 { touchedParts.append(diff.path[3].container) }
        }
        guard !touched.isEmpty else { return }
        lock.lock()
        stale.formUnion(touched)
        staleParts.formUnion(touchedParts)
        lock.unlock()
    }

    /// The doc's messages in list order, re-decoding only changed or unseen
    /// ones. Changes that land mid-read stay marked for the next read.
    /// `assemble` decodes a message whose parts were decoded separately via
    /// `parsePart`; when a message's parts aren't a list of map containers it
    /// falls back to `parse` on the whole deep value.
    func read(_ doc: LoroDoc,
              parse: (LoroValue) -> MessageEntry?,
              parsePart: (LoroValue) -> MessagePart? = { _ in nil },
              assemble: ((LoroMap, [MessagePart]) -> MessageEntry?)? = nil) -> [MessageEntry] {
        lock.lock()
        let changed = stale
        let changedParts = staleParts
        stale = []
        staleParts = []
        let previous = entries
        let previousParts = partCache
        lock.unlock()

        let (count, item) = Self.messages(in: doc)
        var next: [ContainerId: MessageEntry?] = [:]
        var nextParts: [ContainerId: MessagePart?] = [:]
        next.reserveCapacity(Int(count))
        var result: [MessageEntry] = []
        result.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let item = item(index) else { continue }
            if let id = item.asContainer(), let map = item.asLoroMap() {
                let entry: MessageEntry?
                if !changed.contains(id), let cached = previous[id] {
                    entry = cached
                    // Keep the part cache alive for unchanged messages too.
                    if let partsList = map.get(key: "parts")?.asLoroList() {
                        for p in 0..<partsList.len() {
                            if let partId = partsList.get(index: p)?.asContainer(),
                               let cachedPart = previousParts[partId] {
                                nextParts[partId] = cachedPart
                            }
                        }
                    }
                } else {
                    entry = decode(map, parse: parse, parsePart: parsePart,
                                   assemble: assemble, changedParts: changedParts,
                                   previousParts: previousParts, nextParts: &nextParts)
                }
                next[id] = entry
                if let entry { result.append(entry) }
            } else if let value = item.asValue(), let entry = parse(value) {
                result.append(entry)
            }
        }

        lock.lock()
        entries = next
        partCache = nextParts
        lock.unlock()
        return result
    }

    /// Decode one changed message. When `parts` is a list of part-map
    /// containers, re-decode only the parts the diff touched and reuse the
    /// cached decode for the rest; any other shape decodes the whole value.
    private func decode(_ map: LoroMap,
                        parse: (LoroValue) -> MessageEntry?,
                        parsePart: (LoroValue) -> MessagePart?,
                        assemble: ((LoroMap, [MessagePart]) -> MessageEntry?)?,
                        changedParts: Set<ContainerId>,
                        previousParts: [ContainerId: MessagePart?],
                        nextParts: inout [ContainerId: MessagePart?]) -> MessageEntry? {
        guard let assemble,
              let partsList = map.get(key: "parts")?.asLoroList() else {
            return parse(map.getDeepValue())
        }
        var parts: [MessagePart] = []
        parts.reserveCapacity(Int(partsList.len()))
        for i in 0..<partsList.len() {
            guard let item = partsList.get(index: i),
                  let partId = item.asContainer(),
                  let partMap = item.asLoroMap() else {
                // A part that isn't a map container: bail to the whole-value
                // decode rather than guessing at its shape.
                return parse(map.getDeepValue())
            }
            let part: MessagePart?
            if !changedParts.contains(partId), let cached = previousParts[partId] {
                part = cached
            } else {
                part = parsePart(partMap.getDeepValue())
            }
            nextParts[partId] = part
            if let part { parts.append(part) }
        }
        return assemble(map, parts)
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
