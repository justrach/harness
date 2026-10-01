// Edge auth client — CodeGraff OAuth exchange, refresh, and personal workspace.
// - Dev (AUTH_MODE=dev edge): the bearer string IS the user id; "user@org"
//   supplies a fake org claim.

import Foundation

struct AuthUser: Codable, Equatable {
    var id: String
    var email: String?
    var firstName: String?
    var lastName: String?
}

struct AuthOrg: Codable, Identifiable, Equatable {
    var id: String
    var organizationId: String
    var name: String
}

struct AuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
}

enum AuthError: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Auth failed (\(code)): \(body)"
        case .invalidResponse: return "Unexpected auth response"
        }
    }
}

struct AuthClient {
    var baseURL: URL

    func exchange(code: String, codeVerifier: String, redirectURI: String,
                  nonce: String) async throws -> (AuthUser, AuthTokens) {
        struct Response: Codable {
            var user: AuthUser
            var accessToken: String
            var refreshToken: String
        }
        let r: Response = try await post("auth/exchange", body: [
            "code": code, "codeVerifier": codeVerifier,
            "redirectUri": redirectURI, "nonce": nonce,
        ])
        return (r.user, AuthTokens(accessToken: r.accessToken, refreshToken: r.refreshToken))
    }

    func refresh(refreshToken: String, organizationId: String? = nil) async throws -> AuthTokens {
        var body: [String: String] = ["refreshToken": refreshToken]
        if let organizationId { body["organizationId"] = organizationId }
        return try await post("auth/refresh", body: body)
    }

    func orgs(accessToken: String) async throws -> [AuthOrg] {
        struct Response: Codable { var orgs: [AuthOrg] }
        var request = URLRequest(url: baseURL.appending(path: "auth/orgs"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data).orgs
    }

    /// Both halves of the sign-in go along: the edge refuses a delete unless
    /// the access token and refresh credential belong to the same person.
    func deleteAccount(accessToken: String, refreshToken: String) async throws -> AccountDeletion {
        var request = URLRequest(url: baseURL.appending(path: "auth/account/delete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refreshToken": refreshToken, "confirm": "delete"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        return AccountDeletion(status: http.statusCode, data: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data: data, response: response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Keychain storage

enum Keychain {
    private static let service = "harness.codegraff.ios"

    /// Update in place. Delete-then-add left a gap where a kill (or a failed add) lost the item, and a
    /// lost refresh token is a signed-out phone.
    static func save(_ value: String, key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// The pair a sign-in is made of. The refresh token goes first: it is the one that cannot be
    /// replaced, while a missing access token is simply refreshed.
    static func saveTokens(_ tokens: AuthTokens) {
        save(tokens.refreshToken, key: "codegraffRefreshToken")
        save(tokens.accessToken, key: "codegraffAccessToken")
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
