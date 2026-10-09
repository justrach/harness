// Session-wide connection config: edge base URL, identity, token minting for
// room sockets, and the durable-nudge POST. Socket URL providers still mint
// `?token=` URLs; `URLRequest.bearerWebSocket` moves the token into an
// Authorization header before the upgrade is sent. Thread-safe (rooms call
// in from their actors).

import Foundation

extension URLRequest {
    /// A WebSocket upgrade request with any `token` query item moved into an
    /// `Authorization: Bearer` header: a URL can reach request logs, a header
    /// does not. The edge reads the header first and still accepts the query
    /// form, so this works against every deployed edge.
    static func bearerWebSocket(_ url: URL) -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else {
            return URLRequest(url: url)
        }
        let kept = items.filter { $0.name != "token" }
        components.queryItems = kept.isEmpty ? nil : kept
        var request = URLRequest(url: components.url ?? url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
final class AppConfig: @unchecked Sendable {
    enum Mode: String {
        case codegraff
        case dev
    }

    let edgeURL: URL
    let mode: Mode
    let userId: String
    let orgId: String
    let deviceId: String
    let deviceName: String

    private let lock = NSLock()
    private var tokens: AuthTokens?
    private var devBearer: String?
    /// In-flight refresh shared by every caller (single-flight). CodeGraff
    /// refresh tokens are SINGLE-USE (rotated per use, desktop auth.rs
    /// refresh_gate): without this, a cold launch's N room dials raced N
    /// concurrent refreshes with the same token — one won and rotated it,
    /// the rest failed, dialed with the dead access token, got rejected,
    /// and every socket sat in backoff. That was the 5–10s "connecting"
    /// stall on every app open past token expiry (~5 min).
    private var refreshTask: Task<String?, Never>?
    /// A refresh token the edge turned down. Spending it again can only fail (and CodeGraff treats a
    /// replayed token as theft), so it is left alone until a sign-in replaces it.
    private var rejectedRefreshToken: String?
    /// Called once when the edge rejects the stored sign-in: the person must sign in again. Set by AppModel.
    var onSessionExpired: (@Sendable () -> Void)? {
        get { lock.withLock { sessionExpiredHandler } }
        set { lock.withLock { sessionExpiredHandler = newValue } }
    }
    private var sessionExpiredHandler: (@Sendable () -> Void)?

    init(edgeURL: URL, mode: Mode, userId: String, orgId: String,
         deviceId: String, deviceName: String,
         tokens: AuthTokens? = nil, devBearer: String? = nil) {
        self.edgeURL = edgeURL
        self.mode = mode
        self.userId = userId
        self.orgId = orgId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.tokens = tokens
        self.devBearer = devBearer
    }

    func updateTokens(_ new: AuthTokens) {
        lock.withLock {
            tokens = new
            rejectedRefreshToken = nil
        }
    }

    /// The edge turned the stored sign-in down and no new one has replaced it. No request can succeed, so
    /// none is sent (see `currentToken`), and the connection loops stand down.
    var signInRejected: Bool {
        lock.withLock {
            guard let tokens, let rejectedRefreshToken else { return false }
            return rejectedRefreshToken == tokens.refreshToken
        }
    }

    /// What the Connection screen shows about the sign-in. A snapshot; reading it sends nothing.
    struct AuthDiagnostics: Equatable {
        var signedIn: Bool
        var rejected: Bool
        var accessExpiresAt: Date?
        var lastRefreshAt: Date?
        var lastRefreshOutcome: String?
    }

    func authDiagnostics() -> AuthDiagnostics {
        lock.withLock {
            AuthDiagnostics(signedIn: mode == .dev ? devBearer != nil : tokens != nil,
                            rejected: tokens.map { rejectedRefreshToken == $0.refreshToken } ?? false,
                            accessExpiresAt: tokens.flatMap { Self.expiry(ofJWT: $0.accessToken) },
                            lastRefreshAt: lastRefresh?.at,
                            lastRefreshOutcome: lastRefresh?.outcome)
        }
    }

    private var lastRefresh: (at: Date, outcome: String)?

    /// Current bearer, refreshing the CodeGraff access token when needed.
    func currentToken() async -> String? {
        switch mode {
        case .dev:
            return lock.withLock { devBearer }
        case .codegraff:
            let current = lock.withLock { tokens }
            guard let current else { return nil }
            if !Self.isExpired(jwt: current.accessToken) {
                return current.accessToken
            }
            return await refreshedToken(current: current)
        }
    }

    /// The CodeGraff pair with an access token good for at least a minute, so
    /// no room refresh spends the refresh token while a caller holds it.
    func currentTokens() async -> AuthTokens? {
        guard mode == .codegraff, await currentToken() != nil else { return nil }
        return lock.withLock { tokens }
    }

    /// Join (or start) the one in-flight refresh. The task clears itself
    /// under the lock as its last act, so a caller either joins a live
    /// refresh or starts a fresh one — never a second concurrent POST.
    private func refreshedToken(current: AuthTokens) async -> String? {
        // Nothing to send: the edge already refused this sign-in, and a request with a dead token only
        // costs radio time. A new sign-in clears this.
        if lock.withLock({ rejectedRefreshToken }) == current.refreshToken {
            return nil
        }
        let task = lock.withLock {
            if let existing = refreshTask {
                return existing
            }

            let task = Task<String?, Never> { [edgeURL, orgId] in
                // Let a refresh in flight finish if the app is backgrounded: a reply lost after the edge
                // rotated the credential is a signed-out phone.
                let grace = await MainActor.run { BackgroundGrace.begin("harness.refreshToken") }
                defer { grace.end() }
                let client = AuthClient(baseURL: edgeURL)
                let outcome = await TokenRefresh.run {
                    try await client.refresh(refreshToken: current.refreshToken, organizationId: orgId)
                }
                var token: String?
                let label: String
                switch outcome {
                case .refreshed(let refreshed):
                    Keychain.saveTokens(refreshed)
                    self.updateTokens(refreshed)
                    token = refreshed.accessToken
                    label = "refreshed"
                case .rejected:
                    roomLog.error("auth: the edge rejected the stored sign-in; signing in again is needed")
                    let notify = self.lock.withLock { () -> (@Sendable () -> Void)? in
                        self.rejectedRefreshToken = current.refreshToken
                        return self.sessionExpiredHandler
                    }
                    notify?()
                    label = "rejected"
                case .unavailable:
                    roomLog.error("auth: token refresh failed (will retry); using expired access token (server will reject and rooms will redial)")
                    // Undecided, not refused: fall back to the expired token and let the server answer; the
                    // rooms' backoff redials retry through here.
                    token = current.accessToken
                    label = "edge unreachable"
                }
                self.lock.withLock {
                    self.lastRefresh = (Date(), label)
                    self.refreshTask = nil
                }
                return token
            }
            refreshTask = task
            return task
        }
        return await task.value
    }

    private var wsBase: URL {
        var components = URLComponents(url: edgeURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url!
    }

    /// The workspace registry room (docs/registry-sync.md) — the row-table
    /// replacement for the old ws Loro workspace doc.
    func registrySocketURL() async -> URL? {
        guard let token = await currentToken() else { return nil }
        var url = wsBase.appending(path: "registry/\(orgId)/ws")
        url.append(queryItems: [URLQueryItem(name: "token", value: token),
                                URLQueryItem(name: "device", value: deviceId)])
        return url
    }

    /// The chat2 log-relay room (docs/chat2-sync.md B) — replaces the s2
    /// session rooms, which mobile no longer dials at all. `device` rides the
    /// URL so the DO can attribute sockets and honor excludeOwn backfills.
    func chat2SocketURL(chatId: String) async -> URL? {
        guard let token = await currentToken() else { return nil }
        var url = wsBase.appending(path: "chat2/\(chatId)/ws")
        url.append(queryItems: [URLQueryItem(name: "token", value: token),
                                URLQueryItem(name: "device", value: deviceId)])
        return url
    }

    /// GET /chat2/{chatId}/checkpoint — the Range-resumable doc snapshot
    /// (auth via bearer header; the caller adds Range on resume).
    func chat2CheckpointRequest(chatId: String) async -> URLRequest? {
        guard let token = await currentToken() else { return nil }
        var request = URLRequest(url: edgeURL.appending(path: "chat2/\(chatId)/checkpoint"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// GET /chat2/{chatId}/rows?after= — pull over plain HTTPS: one request
    /// collapses the socket's connect→hello→state→rowsReq→backfill, and it
    /// works on networks that strip WS upgrades (airplane wifi).
    func chat2RowsRequest(chatId: String, after: UInt64) async -> URLRequest? {
        guard let token = await currentToken() else { return nil }
        var url = edgeURL.appending(path: "chat2/\(chatId)/rows")
        url.append(queryItems: [URLQueryItem(name: "after", value: String(after)),
                                URLQueryItem(name: "device", value: deviceId)])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// POST /chat2/{chatId}/rows?batchId= — push over plain HTTPS (batchId
    /// dedupe makes replays no-ops); body is the raw update batch.
    func chat2PushRequest(chatId: String, batchId: String) async -> URLRequest? {
        guard let token = await currentToken() else { return nil }
        var url = edgeURL.appending(path: "chat2/\(chatId)/rows")
        url.append(queryItems: [URLQueryItem(name: "batchId", value: batchId),
                                URLQueryItem(name: "device", value: deviceId)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// GET /registry/{orgId}/rows?since= — the WS hello's delta answer over
    /// plain HTTPS. `beat=1` doubles as a presence beat.
    func registryRowsRequest(since: UInt64?) async -> URLRequest? {
        guard let token = await currentToken() else { return nil }
        var url = edgeURL.appending(path: "registry/\(orgId)/rows")
        var items = [URLQueryItem(name: "device", value: deviceId),
                     URLQueryItem(name: "beat", value: "1")]
        if let since { items.append(URLQueryItem(name: "since", value: String(since))) }
        url.append(queryItems: items)
        // Bearer header, never ?token=: HTTP supports headers (unlike WS
        // upgrades), and query strings can reach request logs.
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// POST /registry/{orgId}/push — one op batch over plain HTTPS (LWW
    /// clocks make replays apply zero ops).
    func registryPushRequest() async -> URLRequest? {
        guard let token = await currentToken() else { return nil }
        var url = edgeURL.appending(path: "registry/\(orgId)/push")
        url.append(queryItems: [URLQueryItem(name: "device", value: deviceId)])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// POST /registry/{orgId}/push-target — this phone's APNs token and
    /// notification choices; nil registration is the DELETE (sign-out, or
    /// notifications turned off here).
    func pushTargetRequest(register registration: PushRegistration?) async -> URLRequest? {
        guard let token = await currentToken() else { return nil }
        var url = edgeURL.appending(path: "registry/\(orgId)/push-target")
        url.append(queryItems: [URLQueryItem(name: "device", value: deviceId)])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let registration {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(registration)
        } else {
            request.httpMethod = "DELETE"
        }
        return request
    }

    /// Decode the JWT payload's `exp` (60s early-refresh margin). Unparseable
    /// tokens read as non-expired — the server is the arbiter.
    private static func isExpired(jwt: String) -> Bool {
        guard let exp = expiry(ofJWT: jwt) else { return false }
        return Date() > exp.addingTimeInterval(-60)
    }

    /// The JWT payload's `exp`, or nil when the token does not parse.
    static func expiry(ofJWT jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// GET /device/{deviceId}/status → whether the device's relay HOST socket
    /// is currently attached (distinct from workspace presence).
    func deviceStatus(deviceId: String) async -> String {
        guard let token = await currentToken() else { return "no-token" }
        var request = URLRequest(url: edgeURL.appending(path: "device/\(deviceId)/status"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return "unreachable" }
        return "http=\(http.statusCode) body=\(String(data: data, encoding: .utf8) ?? "")"
    }

    /// POST /device/{deviceId}/nudge {chatId} — wake a cold host to drain the
    /// command queue.
    func nudge(deviceId: String, chatId: String) async {
        guard let token = await currentToken() else { return }
        var request = URLRequest(url: edgeURL.appending(path: "device/\(deviceId)/nudge"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["chatId": chatId])
        _ = try? await URLSession.shared.data(for: request)
    }
}
