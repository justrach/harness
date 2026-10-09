// Agent credentials belong to the execution host. The phone may approve a
// device-code login, or finish graff's ChatGPT sign-in in its own browser and
// hand the redirect back, but token exchange and credential storage stay on
// the host (it holds the PKCE verifier).
import Foundation
import Observation

struct AgentLoginStart: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable {
        case browser, hostBrowser = "host-browser", pasteCode = "paste-code", deviceCode = "device-code"
        case relayBrowser = "relay-browser"
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
    /// Hand the host the redirect a phone-browser sign-in landed on.
    func complete(loginId: String, redirect: String) async throws
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

    func complete(loginId: String, redirect: String) async throws {
        let _: AgentLoginAcknowledgement = try await relay.call(
            method: "CompleteAgentLogin", params: ["loginId": loginId, "code": redirect],
            timeoutSeconds: 30)
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

    /// graff's ChatGPT sign-in, finished in this phone's browser. Only OpenAI's
    /// authorize page with a 127.0.0.1 redirect qualifies; the host re-checks the
    /// redirect against its own sign-in before delivering it.
    struct BrowserSignIn: Equatable, Sendable {
        let url: URL
        let callbackPort: Int
        let callbackPath: String

        fileprivate init?(url: String) {
            guard let parsed = URLComponents(string: url),
                  parsed.scheme == "https", parsed.host == "auth.openai.com",
                  parsed.user == nil, parsed.password == nil, parsed.port == nil,
                  parsed.fragment == nil, parsed.path == "/api/accounts/authorize",
                  let items = parsed.queryItems,
                  items.contains(where: { $0.name == "state" && !($0.value ?? "").isEmpty }),
                  let redirectValue = items.first(where: { $0.name == "redirect_uri" })?.value,
                  let redirect = URLComponents(string: redirectValue),
                  redirect.scheme == "http", redirect.host == "127.0.0.1",
                  let port = redirect.port, !redirect.path.isEmpty,
                  redirect.query == nil, redirect.fragment == nil,
                  let approvedURL = parsed.url else { return nil }
            self.url = approvedURL
            self.callbackPort = port
            self.callbackPath = redirect.path
        }

        /// The browser reached this sign-in's loopback redirect.
        func isCallback(_ url: URL) -> Bool {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            return parts.scheme == "http" && parts.host == "127.0.0.1"
                && parts.port == callbackPort && parts.path == callbackPath
        }
    }

    private(set) var approval: Approval?
    private(set) var browserSignIn: BrowserSignIn?
    /// The redirect went to the host, which is now finishing the sign-in.
    private(set) var handedOff = false
    private var loginId: String?
    @ObservationIgnored private var generation: UInt64 = 0
    /// Attempts ended by an explicit Cancel: a sign-in that starts late for one of them is ended too.
    @ObservationIgnored private var cancelledAttempts: Set<UInt64> = []
    @ObservationIgnored private let transport: (any AgentLoginTransport)?
    @ObservationIgnored private let pollDelay: @MainActor () async throws -> Void

    init(transport: (any AgentLoginTransport)?,
         pollDelay: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(nanoseconds: 2_000_000_000)
         }) {
        self.transport = transport
        self.pollDelay = pollDelay
    }

    /// Explicit Cancel: ends the sign-in on the host for everyone waiting on it.
    func cancel() {
        let oldId = loginId
        cancelledAttempts.insert(generation)
        detach()
        if let oldId, let transport {
            Task { await transport.cancel(loginId: oldId) }
        }
    }

    /// Stop watching without ending the host's sign-in (the sheet was dismissed, or the task that
    /// ran it was cancelled). Reopening attaches to the same approval: the host coalesces
    /// recoveries per route and account.
    func detach() {
        generation &+= 1
        loginId = nil
        approval = nil
        browserSignIn = nil
        handedOff = false
        redirectError = nil
        phase = .idle
    }

    /// Finish a phone-browser sign-in: send the address the browser landed on
    /// (caught in the in-app browser, or pasted after Safari). The host checks
    /// it is this sign-in's redirect; polling then reports the outcome.
    @discardableResult
    func finish(redirect: String) async -> Bool {
        let landed = redirect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .waiting, let signIn = browserSignIn, let loginId, let transport,
              !handedOff else { return false }
        guard let url = URL(string: landed), signIn.isCallback(url) else {
            redirectError = "That isn't the address ChatGPT sent you to. Copy the whole address of the page that didn't load."
            return false
        }
        let attempt = generation
        redirectError = nil
        handedOff = true
        do {
            try await transport.complete(loginId: loginId, redirect: landed)
            return generation == attempt
        } catch {
            guard generation == attempt else { return false }
            handedOff = false
            switch error {
            case RelayError.hostOffline, RelayError.notConnected:
                redirectError = "The execution device is offline. Reconnect it and try again."
            default:
                // Host text may echo the redirect; keep a fixed message.
                redirectError = "The execution device didn't accept this sign-in. Start again."
            }
            return false
        }
    }

    /// Why the last redirect wasn't handed to the host.
    private(set) var redirectError: String?

    /// User-triggered only. Late start/poll responses cannot restore a
    /// dismissed sheet or overwrite a replacement attempt's state.
    func run(provider: AgentReauthProvider) async {
        detach()
        let attempt = generation
        phase = .starting
        guard let transport else {
            phase = .failed("The execution device is unavailable. Reconnect it and try again.")
            return
        }
        do {
            let started = try await transport.start(provider: provider)
            // Dismissed while starting: leave the host's sign-in running; reopening attaches.
            // Cancelled explicitly: end the sign-in that just started.
            guard generation == attempt, !Task.isCancelled else {
                if generation == attempt { detach() }
                if cancelledAttempts.remove(attempt) != nil {
                    await transport.cancel(loginId: started.loginId)
                }
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
            case .relayBrowser:
                // graff's ChatGPT sign-in, finished in this phone's browser.
                guard provider == .chatGPTNew, started.code == nil || started.code == "",
                      let signIn = BrowserSignIn(url: started.url) else {
                    throw RelayError.rpc("The execution device returned invalid sign-in details.")
                }
                browserSignIn = signIn
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
                    browserSignIn = nil
                    handedOff = false
                    phase = .done
                case .error:
                    // Do not retain arbitrary host output or OAuth material.
                    throw RelayError.rpc("Sign-in failed. Try again on the execution device.")
                }
            }
            if generation == attempt, Task.isCancelled { detach() }
        } catch {
            guard generation == attempt else { return }
            if Task.isCancelled || error is CancellationError {
                detach()
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
                message = browserSignIn != nil
                    ? "ChatGPT sign-in didn't finish. Sign in again, and allow plan usage when asked."
                    : "Sign-in failed. Try again on the execution device."
            }
            cancel()
            phase = .failed(message)
        }
    }
}

/// Recoveries that succeeded in this app session, and the rows whose one Resume was sent. Memory
/// only: a relaunch shows the row's first step again, and the host attaches to any approval still
/// waiting.
@MainActor
@Observable
final class ReauthOutcomes {
    static let shared = ReauthOutcomes()

    private(set) var resolved: Set<String> = []
    private(set) var resumed: Set<String> = []

    static func key(chatId: String, rowId: String) -> String { "\(chatId)|\(rowId)" }

    func resolve(_ key: String) { resolved.insert(key) }

    /// Claim a row's one Resume. `false` when the row isn't reconnected or was already resumed.
    func claimResume(_ key: String) -> Bool {
        resolved.contains(key) && resumed.insert(key).inserted
    }

    /// A Resume that couldn't be sent: the row offers it again.
    func releaseResume(_ key: String) { resumed.remove(key) }
}

enum ReauthCopy {
    /// The turn Resume sends: a continuation, never the failed prompt.
    static let resumePrompt = "Continue where you left off. The previous turn stopped because ChatGPT needed reconnecting; it is connected again now."
    /// Harness has no signal for either case, so this never says one applies, and never suggests
    /// turning account security off.
    static let accountSecurityNote = "If you recently reset your password or enrolled in Advanced Account Security (including Daybreak), ChatGPT may ask you to sign in again."
}
