// The session doc's pending-message queue, from the phone's side
// (crates/doc/src/queue.rs).
//
// Unlike `messages` — host-only — every device may write here, so these are
// plain doc edits for enqueue and reorder. Protected edits and removal ask
// the host to serialize with delivery. Local list changes sync out
// with the next update. A MovableList because reordering is a real move op:
// two devices dragging at once converge on one order with every row intact,
// where a delete+insert list would duplicate or lose rows.
//
// Delivery, protected editing and cancellation are host-authoritative.
// A local projection only removes a row after a successful host ACK.

import Foundation
import Loro

private struct QueueWriteFailed: Error {}

extension SessionStore {
    // MARK: Read

    nonisolated static func queuedFrom(_ value: LoroValue) -> QueuedMessage? {
        guard let m = value.mapValue,
              let id = m["id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
              let text = m["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return QueuedMessage(
            id: id,
            text: text,
            attachments: (m["attachments"]?.listValue ?? []).compactMap(\.stringValue),
            issuedBy: m["issuedBy"]?.stringValue ?? "",
            issuedAt: m["issuedAt"]?.i64Value ?? 0,
            editedAt: m["editedAt"]?.i64Value,
            holdForTurnEnd: m["holdForTurnEnd"]?.boolValue ?? false,
            deliveryGate: queueDeliveryGate(from: m["deliveryGate"])
        )
    }

    nonisolated private static func queueDeliveryGate(from value: LoroValue?) -> QueueDeliveryGate? {
        guard let gate = value?.mapValue, let kind = gate["kind"]?.stringValue else { return nil }
        let owner = gate["ownerDeviceId"]?.stringValue ?? "another device"
        switch kind {
        case "editing":
            return .editing(ownerDeviceId: owner,
                            expiresAtMs: gate["expiresAtMs"]?.i64Value ?? 0)
        case "reviewRequired":
            return .reviewRequired(ownerDeviceId: owner)
        default:
            // Unknown future gates fail closed in the UI too.
            return .reviewRequired(ownerDeviceId: owner)
        }
    }

    // MARK: Write

    /// Park a message on the queue. The host decides where it goes from there —
    /// straight into the running turn, or the front of the next one.
    @discardableResult
    func enqueueMessage(text: String, attachments: [String] = [],
                        holdForTurnEnd: Bool = true) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID().uuidString.lowercased()
        let deviceId = self.deviceId
        let issuedAt = nowMs()
        let attachmentsValue = LoroValue.fromJSON(attachments)
        let written = writeDoc({ doc in
            let list = doc.getMovableList(id: "queue")
            do {
                let map = try list.insertMapContainer(pos: list.len(), child: LoroMap())
                try map.insert(key: "id", v: id)
                try map.insert(key: "text", v: text)
                try map.insert(key: "issuedBy", v: deviceId)
                try map.insert(key: "issuedAt", v: issuedAt)
                if holdForTurnEnd {
                    try map.insert(key: "holdForTurnEnd", v: true)
                }
                if !attachments.isEmpty {
                    try map.insert(key: "attachments", v: attachmentsValue)
                }
                doc.commit()
                return true
            } catch {
                return false
            }
        }, then: { [weak self] ok in
            self?.refreshQueue()
            if ok { self?.nudgeHost() }
        })
        if written == nil {
            showQueue(queue + [QueuedMessage(id: id, text: text, attachments: attachments,
                                             issuedBy: deviceId, issuedAt: issuedAt,
                                             holdForTurnEnd: holdForTurnEnd)])
        }
        return written == false ? nil : id
    }

    // MARK: Protected editing

    func beginQueuedEdit(id: String, instanceId: String) async -> QueueEditStartResult {
        struct Reply: Decodable {
            var outcome: String
            var leaseId: String?
            var text: String?
            var baseTextHash: String?
            var expiresAtMs: Int64?
            var attachments: [String]?
        }
        guard !queueActionsPending.contains(id),
              queue.contains(where: { $0.id == id }), let relay = hostRelayClient() else {
            return .unavailable
        }
        do {
            let reply: Reply = try await relay.call(
                method: "BeginQueuedMessageEdit",
                params: [
                    "chatId": chatId,
                    "id": id,
                    "editorDeviceId": deviceId,
                    "editorInstanceId": instanceId,
                ]
            )
            switch reply.outcome {
            case "acquired":
                guard let leaseId = reply.leaseId,
                      let baseTextHash = reply.baseTextHash,
                      let expiresAtMs = reply.expiresAtMs else { return .unavailable }
                return .acquired(QueueEditLease(
                    rowId: id,
                    leaseId: leaseId,
                    text: reply.text ?? "",
                    baseTextHash: baseTextHash,
                    expiresAtMs: expiresAtMs,
                    attachments: reply.attachments
                ))
            case "locked": return .locked
            default: return .missing
            }
        } catch {
            roomLog.warning(
                "chat2 \(self.chatId, privacy: .public): begin queue edit failed for \(id, privacy: .public)"
            )
            return .unavailable
        }
    }

    func renewQueuedEdit(_ lease: QueueEditLease) async -> Bool {
        struct Reply: Decodable { var outcome: String }
        guard let relay = hostRelayClient() else { return false }
        do {
            let reply: Reply = try await relay.call(
                method: "RenewQueuedMessageEdit",
                params: ["chatId": chatId, "id": lease.rowId, "leaseId": lease.leaseId]
            )
            return reply.outcome == "renewed"
        } catch {
            return false
        }
    }

    /// `FinishQueuedMessageEdit` params. `attachments` nil leaves the row's
    /// list alone; a list (even empty) replaces it on commit, which is how
    /// the desktop saves a queued message's images (crates/ui/src/queue.rs).
    nonisolated static func finishQueuedEditParams(chatId: String, lease: QueueEditLease,
                                                   action: String, text: String? = nil,
                                                   attachments: [String]? = nil) -> [String: Any] {
        var params: [String: Any] = [
            "chatId": chatId,
            "id": lease.rowId,
            "leaseId": lease.leaseId,
            "action": action,
            "expectedTextHash": lease.baseTextHash,
        ]
        if let text { params["text"] = text }
        if let attachments { params["attachments"] = attachments }
        return params
    }

    func finishQueuedEdit(_ lease: QueueEditLease, action: String,
                          text: String? = nil) async -> QueueEditFinishResult {
        await finishQueuedEdit(lease, params: Self.finishQueuedEditParams(
            chatId: chatId, lease: lease, action: action, text: text))
    }

    func finishQueuedEdit(_ lease: QueueEditLease, params: [String: Any]) async -> QueueEditFinishResult {
        struct Reply: Decodable { var outcome: String }
        guard let relay = hostRelayClient() else { return .unavailable }
        do {
            // Attachments ride on a commit, so give it the desktop's 30s.
            let reply: Reply = try await relay.call(
                method: "FinishQueuedMessageEdit", params: params,
                timeoutSeconds: params["attachments"] == nil ? 10 : 30
            )
            switch reply.outcome {
            case "committed", "cancelled", "discarded", "released": return .finished
            case "conflict": return .conflict
            case "missing": return .missing
            default: return .lost
            }
        } catch {
            roomLog.warning(
                "chat2 \(self.chatId, privacy: .public): finish queue edit failed for \(lease.rowId, privacy: .public)"
            )
            return .unavailable
        }
    }

    /// Demo mode has no host to commit a protected edit, so the attachments
    /// editor writes the row in place, the way the host's
    /// `finish_queued_edit_with_attachments` does: same map, same slot, only
    /// `text` and `attachments` change.
    @discardableResult
    func applyQueuedAttachmentsLocally(id: String, text: String, attachments: [String]) -> Bool {
        let list = doc.getMovableList(id: "queue")
        guard let index = Self.queueIndex(of: id, in: list),
              let row = list.get(index: UInt32(index))?.asLoroMap() else { return false }
        do {
            try row.insert(key: "text", v: text)
            try row.insert(key: "attachments", v: LoroValue.fromJSON(attachments))
            try row.insert(key: "editedAt", v: nowMs())
            doc.commit()
        } catch {
            return false
        }
        refreshQueue()
        return true
    }

    /// Move a row to `to`, clamped to the queue. Same slot is a no-op.
    func moveQueued(id: String, to: Int) {
        guard !queueActionsPending.contains(id),
              queue.first(where: { $0.id == id })?.deliveryGate == nil else { return }
        let written = writeDoc({ doc in
            let list = doc.getMovableList(id: "queue")
            let count = Int(list.len())
            guard count > 0, let from = Self.queueIndex(of: id, in: list) else { return false }
            let target = min(max(to, 0), count - 1)
            guard from != target else { return false }
            do {
                try list.mov(from: UInt32(from), to: UInt32(target))
                doc.commit()
                return true
            } catch {
                return false
            }
        }, then: { [weak self] _ in self?.refreshQueue() })
        if written == nil, let from = queue.firstIndex(where: { $0.id == id }) {
            var next = queue
            let row = next.remove(at: from)
            next.insert(row, at: min(max(to, 0), next.count))
            showQueue(next)
        }
    }

    /// Nudge a row one slot up (-1) or down (+1).
    func moveQueued(id: String, by direction: Int) {
        guard let from = queue.firstIndex(where: { $0.id == id }),
              let to = MessageQueue.neighbour(of: from, direction: direction, count: queue.count)
        else { return }
        moveQueued(id: id, to: to)
    }

    /// The host serializes these actions with delivery. Never delete locally
    /// before its ACK; a lost reply is uncertain and leaves sync to reconcile.
    @discardableResult
    func performQueueAction(id: String, action: QueueAction,
                            call: ((String, [String: String]) async throws -> QueueActionReply)? = nil) async -> Bool {
        guard let row = queue.first(where: { $0.id == id }),
              !queueActionsPending.contains(id) else { return false }
        guard action == .remove || row.deliveryGate == nil else { return false }
        queueActionsPending.insert(id)
        queueActionError = nil
        defer { queueActionsPending.remove(id) }
        do {
            let params = ["chatId": chatId, "id": id]
            let reply: QueueActionReply
            if let call {
                reply = try await call(action.method, params)
            } else {
                guard let relay = hostRelayClient() else { throw RelayError.hostOffline }
                reply = try await relay.call(method: action.method, params: params)
            }
            guard reply.acknowledged(action) else {
                queueActionError = "The host did not confirm the action. The message may have already left the queue."
                kickRoom()
                return false
            }
            // Apply only a confirmed removal. Sends leave projection to sync.
            if action == .remove {
                let written = writeDoc({ doc in
                    let list = doc.getMovableList(id: "queue")
                    guard let index = Self.queueIndex(of: id, in: list) else { return true }
                    do {
                        try list.delete(pos: UInt32(index), len: 1)
                        doc.commit()
                        return true
                    } catch {
                        return false
                    }
                }, then: { [weak self] _ in self?.refreshQueue() })
                if written == nil { showQueue(queue.filter { $0.id != id }) }
                if written == false { throw QueueWriteFailed() }
            }
            return true
        } catch {
            roomLog.warning("queue action \(action.method, privacy: .public) failed for \(id, privacy: .public): \(describeTransportError(error), privacy: .public)")
            queueActionError = "Couldn't complete \(action.label.lowercased()). Check the connection to the chat host and the queue before retrying."
            kickRoom()
            return false
        }
    }

    // MARK: Plumbing

    nonisolated private static func queueIndex(of id: String, in list: LoroMovableList) -> Int? {
        (0..<Int(list.len())).first { i in
            list.get(index: UInt32(i))?.asLoroMap()?.get(key: "id")?.asValue()?.stringValue == id
        }
    }

}
