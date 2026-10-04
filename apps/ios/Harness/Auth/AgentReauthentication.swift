// Agent credentials belong to the execution host. The phone may approve a
// device-code login, but token exchange and credential storage stay on the host.
// A host-browser fallback never exposes its loopback OAuth URL.
import Foundation
import Observation

struct AgentLoginStart: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable {
        case browser, hostBrowser = "host-browser", pasteCode = "paste-code", deviceCode = "device-code"
    }
    let loginId: String
    let url: String
    let mode: Mode
    let code: String?
}

struct AgentLoginPoll: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case pending, done, error }
    let status: Status
    let message: String?
    let url: String?
}

private struct AgentLoginAcknowledgement: Decodable {}

@MainActor
protocol AgentLoginTransport {
    func start(provider: AgentReauthProvider) async throws -> AgentLoginStart
    func poll(loginId: String) async throws -> AgentLoginPoll
    func cancel(loginId: String) async
}

/// SessionStore selects the chat's host once, including for cleanup.
struct RelayAgentLoginTransport: AgentLoginTransport {
    let relay: DeviceRelayClient

    func start(provider: AgentReauthProvider) async throws -> AgentLoginStart {
        try await relay.call(method: "StartAgentLogin", params: provider.startParameters,
                             timeoutSeconds: 60)
    }

    func poll(loginId: String) async throws -> AgentLoginPoll {
        try await relay.call(method: "PollAgentLogin", params: ["loginId": loginId])
    }

    func cancel(loginId: String) async {
        let _: AgentLoginAcknowledgement? = try? await relay.call(
            method: "CancelAgentLogin", params: ["loginId": loginId])
    }
}

@MainActor
@Observable
final class AgentReauthentication {
    enum Phase: Equatable { case idle, starting, waiting, done, failed(String) }
    private(set) var phase: Phase = .idle

    /// Only a validated start response can supply phone approval details.
    /// Poll responses cannot replace this with an OAuth/callback URL.
    struct Approval: Equatable, Sendable {
        let url: URL
        let code: String

        fileprivate init?(url: String, code: String?) {
            // Exact spelling rejects credentials, ports, queries, fragments,
            // alternate hosts, and URL normalization/encoding tricks.
            guard url == "https://auth.openai.com/codex/device",
                  let code, (4...32).contains(code.utf8.count),
                  code.utf8.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte)
                          || (48...57).contains(byte) || byte == 45
                  }), let approvedURL = URL(string: url) else { return nil }
            self.url = approvedURL
            self.code = code
        }
    }

    private(set) var approval: Approval?
    private var loginId: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let transport: (any AgentLoginTransport)?
    @ObservationIgnored private let pollDelay: @MainActor () async throws -> Void

    init(transport: (any AgentLoginTransport)?,
         pollDelay: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(nanoseconds: 2_000_000_000)
         }) {
        self.transport = transport
        self.pollDelay = pollDelay
    }

    func cancel() {
        generation &+= 1
        let oldId = loginId
        loginId = nil
        approval = nil
        phase = .idle
        if let oldId, let transport {
            Task { await transport.cancel(loginId: oldId) }
        }
    }

    /// User-triggered only. Late start/poll responses cannot restore a
    /// dismissed sheet or overwrite a replacement attempt's state.
    func run(provider: AgentReauthProvider) async {
        cancel()
        let attempt = generation
        phase = .starting
        guard let transport else {
            phase = .failed("The execution device is unavailable. Reconnect it and try again.")
            return
        }
        do {
            let started = try await transport.start(provider: provider)
            guard generation == attempt, !Task.isCancelled else {
                if generation == attempt { cancel() }
                await transport.cancel(loginId: started.loginId)
                return
            }
            guard !started.loginId.isEmpty else {
                throw RelayError.rpc("The execution device returned an invalid sign-in response.")
            }
            loginId = started.loginId
            switch started.mode {
            case .deviceCode:
                // Only legacy Codex supports phone approval in this release.
                // chatgpt-new must complete its browser callback on the host.
                guard provider == .codex,
                      let safeApproval = Approval(url: started.url, code: started.code) else {
                    throw RelayError.rpc("The execution device returned invalid sign-in approval details.")
                }
                approval = safeApproval
            case .hostBrowser:
                guard started.url.isEmpty, started.code == nil || started.code == "" else {
                    throw RelayError.rpc("The execution device returned invalid desktop sign-in details.")
                }
            case .browser, .pasteCode:
                throw RelayError.rpc("Update Harness on the execution device to use supported sign-in recovery.")
            }
            phase = .waiting
            while generation == attempt, phase == .waiting, !Task.isCancelled {
                try await pollDelay()
                guard generation == attempt, phase == .waiting, !Task.isCancelled else { break }
                let reply = try await transport.poll(loginId: started.loginId)
                guard generation == attempt, phase == .waiting, !Task.isCancelled else { break }
                switch reply.status {
                case .pending:
                    // Never open or retain authorization URLs from a poll.
                    break
                case .done:
                    loginId = nil
                    approval = nil
                    phase = .done
                case .error:
                    // Do not retain arbitrary host output or OAuth material.
                    throw RelayError.rpc("Sign-in failed. Try again on the execution device.")
                }
            }
            if generation == attempt, Task.isCancelled { cancel() }
        } catch {
            guard generation == attempt else { return }
            if Task.isCancelled || error is CancellationError {
                cancel()
                return
            }
            let message: String
            switch error {
            case RelayError.hostOffline, RelayError.notConnected:
                message = "The execution device is offline. Reconnect it and try again."
            case RelayError.timeout:
                message = "The execution device did not respond. Check its connection and try again."
            default:
                // Relay/CLI error text may contain authorization URLs or tokens.
                message = "Sign-in failed. Try again on the execution device."
            }
            cancel()
            phase = .failed(message)
        }
    }
}
