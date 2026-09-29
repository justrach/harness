// Sign in with ChatGPT (plan usage) as Graff's login, driven from the phone (ChatGPTSignIn.kt on Android). The browser
// step runs on the computer that hosts Graff: OpenAI's redirect is a loopback on that machine and there is no device
// code, so the phone starts the sign-in there, shows the wait and shows the outcome. It never opens the browser and
// never sees a token. The rules are pinned in `apps/parity/vectors/chatgpt-sign-in.json`.

import Foundation
import Observation

/// What the sign-in sheet is showing.
enum ChatGPTPhase: String, CaseIterable {
    case idle
    /// Started on the computer; waiting for the person to approve in its browser.
    case waiting
    /// Signed in and plan usage granted.
    case connected
    /// Signed in, but the token does not grant plan usage, so it cannot run requests on the plan.
    case planUsageOff
    case declined
    case failed
}

/// What the one main button does on a screen.
enum ChatGPTAction: String {
    case start, cancel, done, retry
}

/// The computer's answer to a poll: the engine's agent-login status, and whether plan usage was granted.
struct ChatGPTPoll: Equatable {
    var status: String
    var planUsage: Bool?
}

enum ChatGPTSignIn {
    /// OpenAI's page for the plan's usage, linked as "Manage usage".
    static let manageUsageURL = "https://chatgpt.com/settings/usage"

    /// Plan usage counts only when the computer says it was granted; a sign-in that does not say is not treated as ready.
    static func phase(for poll: ChatGPTPoll) -> ChatGPTPhase {
        switch poll.status {
        case "pending": .waiting
        case "succeeded": poll.planUsage == true ? .connected : .planUsageOff
        case "plan-not-allowed": .planUsageOff
        case "declined": .declined
        default: .failed
        }
    }

    static func action(in phase: ChatGPTPhase) -> ChatGPTAction {
        switch phase {
        case .idle: .start
        case .waiting: .cancel
        case .connected: .done
        case .planUsageOff, .declined, .failed: .retry
        }
    }
}

/// A computer that can run the sign-in: online, with Graff on it.
struct ChatGPTComputer: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The calls the sign-in makes on a computer. Demo only until the engine ships them; with no client the phone offers nothing.
protocol ChatGPTSignInClient: Sendable {
    var pollInterval: Duration { get }
    /// Starts the sign-in on the computer, which opens its browser.
    func start(deviceId: String) async throws
    func poll(deviceId: String) async -> ChatGPTPoll
    func cancel(deviceId: String) async
}

/// One sign-in from tap to outcome.
@MainActor @Observable
final class ChatGPTSignInFlow {
    private(set) var phase: ChatGPTPhase = .idle
    private let client: any ChatGPTSignInClient
    private var task: Task<Void, Never>?

    init(client: any ChatGPTSignInClient) { self.client = client }

    func start(deviceId: String) {
        task?.cancel()
        phase = .waiting
        task = Task { [weak self, client] in
            do { try await client.start(deviceId: deviceId) } catch {
                self?.phase = .failed
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: client.pollInterval)
                if Task.isCancelled { return }
                let next = ChatGPTSignIn.phase(for: await client.poll(deviceId: deviceId))
                guard let self, !Task.isCancelled else { return }
                phase = next
                if next != .waiting { return }
            }
        }
    }

    /// Stops waiting and tells the computer to close its callback listener.
    func cancel(deviceId: String) {
        task?.cancel()
        let wasWaiting = phase == .waiting
        phase = .idle
        if wasWaiting { Task { [client] in await client.cancel(deviceId: deviceId) } }
    }

    func stop() { task?.cancel() }
}

/// Stands in for the engine in the demo: answers "pending" for a few seconds, then the outcome the launch argument picked.
actor DemoChatGPTSignIn: ChatGPTSignInClient {
    nonisolated let pollInterval: Duration = .milliseconds(500)
    private let outcome: ChatGPTPoll
    private var polls = 0

    /// `name` is a phase: connected, planUsageOff, declined or failed.
    init(outcome name: String) {
        switch name {
        case "planUsageOff": outcome = ChatGPTPoll(status: "succeeded", planUsage: false)
        case "declined": outcome = ChatGPTPoll(status: "declined")
        case "failed": outcome = ChatGPTPoll(status: "error")
        default: outcome = ChatGPTPoll(status: "succeeded", planUsage: true)
        }
    }

    func start(deviceId: String) async throws { polls = 0 }

    func poll(deviceId: String) async -> ChatGPTPoll {
        polls += 1
        return polls <= 6 ? ChatGPTPoll(status: "pending") : outcome
    }

    func cancel(deviceId: String) async {}
}
