// What the Apple Watch bridge (WatchBridge) asks of the app model.

import Foundation

extension AppModel.Phase {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

extension AppModel {
    enum WatchChatFailure: Error, Equatable {
        case noComputer
        case noAutoModels
        case notCreated

        var sentence: String {
            switch self {
            case .noComputer: "None of your computers is online to start a chat."
            case .noAutoModels: ChatMode.unavailableNote
            case .notCreated: "Couldn't start a chat. Open Harness on your iPhone and try again."
            }
        }
    }

    /// "New chat" from the Watch: a plain chat (chat mode) on the computer
    /// the latest chat ran on, or another online one, on the Auto tier the
    /// new-session screen last used.
    func startChatForWatch() async -> Result<Chat, WatchChatFailure> {
        // Online first; one not heard from yet (a background launch before
        // presence arrives) still beats none. Never one known to be offline.
        let usable = executionDevices.filter { hostStatus($0.id) != .offline }
        let candidates = usable.filter { deviceOnline($0.id) } + usable.filter { !deviceOnline($0.id) }
        let latest = overviewChats.max { $0.calledAt < $1.calledAt }?.deviceId
        guard let device = candidates.first(where: { $0.id == latest }) ?? candidates.first else {
            return .failure(.noComputer)
        }
        let catalog = await listModels(deviceId: device.id, harness: ChatMode.harness)
        let stored = UserDefaults.standard.string(forKey: "newChatModel") ?? ""
        let model = ChatMode.selectedModel(storedId: stored, catalog: catalog.items, loading: false)
        guard !model.id.isEmpty else { return .failure(.noAutoModels) }
        let config = ChatConfig(harness: ChatMode.harness, model: model.id, reasoning: nil,
                                sandbox: "workspace-write", chatMode: true)
        guard let id = createProjectlessChat(deviceId: device.id, config: config), let chat = chat(id: id) else {
            return .failure(.notCreated)
        }
        return .success(chat)
    }
}
