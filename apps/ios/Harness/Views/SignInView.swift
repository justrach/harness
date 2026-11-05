// Sign-in with CodeGraff OAuth and PKCE. The edge verifies the OIDC identity.
// The harness mark on black, one white button — the old mobile app's Gate.
//
// Endpoints are fixed to production (the old app's rule: mobile always talks
// to prod; a stale override once broke sign-in in the worst ghost way).

import CryptoKit
import SwiftUI

/// Production cloud endpoints — mirrors edge/wrangler.jsonc.
enum Endpoints {
    static let privacyURL = URL(string: "https://codegraff.com/privacy#harness")!
    static let supportURL = URL(string: "https://codegraff.com/support")!
    static let supportEmailURL = URL(string: "mailto:rach@codegraff.com")!
    static let edgeURL = URL(string: "https://edge.codegraff.com")!
    static let codegraffClientId = "cg_client_43e753878956c2cf7b5b0f53"
    static let codegraffAPIBase = "https://codegraff.com"
    static let callbackScheme = "harness"
    static let redirectURI = "https://edge.codegraff.com/auth/ios/callback"

    static func authorizeURL(state: String, challenge: String) -> URL {
        var components = URLComponents(string: "\(codegraffAPIBase)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: codegraffClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid email offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 24) {
                    HarnessMark()
                        .frame(width: 72, height: 72)
                    VStack(spacing: 6) {
                        Text("Harness")
                            .font(Theme.sans(28, weight: .semibold))
                            .kerning(-0.5)
                            .foregroundStyle(Theme.text)
                        Text("Your coding agents, from anywhere")
                            .font(Theme.sans(15))
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        model.startSignIn()
                    } label: {
                        Group {
                            if model.signInBusy {
                                ProgressView()
                                    .tint(Theme.bg)
                            } else {
                                Text("Log in to Harness")
                                    .font(Theme.sans(15, weight: .semibold))
                                    .foregroundStyle(Theme.bg)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.signInBusy)
                    .opacity(model.signInBusy ? 0.6 : 1)

                    if let error = model.signInError {
                        Text(error)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 20) {
                        Link("Privacy policy", destination: Endpoints.privacyURL)
                        Link("Help", destination: Endpoints.supportURL)
                    }
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                }

                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
        }
    }
}

// MARK: - Auth session plumbing

@objc private protocol WebAuthSessionAPI: NSObjectProtocol {
    @objc(initWithURL:callbackURLScheme:completionHandler:)
    init(url: URL, callbackURLScheme: String?, completionHandler: @escaping (URL?, Error?) -> Void)
    var presentationContextProvider: AnyObject? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    @discardableResult func start() -> Bool
    func cancel()
}

/// Wraps ASWebAuthenticationSession with a presentation anchor. The framework
/// loads when a sign-in starts (LateFramework).
@MainActor
final class AuthSessionCoordinator: NSObject {
    enum Outcome: Equatable {
        case success(URL)
        case cancelled
        case failure(String)
    }

    /// ASWebAuthenticationSessionError: its domain and `.canceledLogin`.
    nonisolated static let sessionErrorDomain = "com.apple.AuthenticationServices.WebAuthenticationSession"
    nonisolated static let canceledLoginCode = 1

    private var session: WebAuthSessionAPI?
    /// Moves on each start and cancel, so a sign-in cancelled while the framework
    /// was still loading doesn't open its sheet.
    private var attempt = 0

    /// Close the sheet: the sign-in finished somewhere else (a magic link
    /// opened in Safari). The completion then reports `.cancelled`.
    func cancel() {
        attempt += 1
        session?.cancel()
        session = nil
    }

    func start(url: URL, callbackScheme: String, completion: @escaping (Outcome) -> Void) {
        attempt += 1
        let started = attempt
        Task { @MainActor in
            let loaded = await LateFramework.authenticationServices.load()
            guard started == attempt else {
                completion(.cancelled)
                return
            }
            guard loaded, let session = makeSession(url: url, callbackScheme: callbackScheme, completion: completion) else {
                completion(.failure("Sign-in failed"))
                return
            }
            self.session = session
            session.start()
        }
    }

    /// Nil until the framework is loaded.
    private func makeSession(url: URL, callbackScheme: String,
                             completion: @escaping (Outcome) -> Void) -> WebAuthSessionAPI? {
        guard let sessionClass = NSClassFromString("ASWebAuthenticationSession") else { return nil }
        LateFramework.adopt("ASWebAuthenticationPresentationContextProviding", on: AuthSessionCoordinator.self)
        let session = unsafeBitCast(sessionClass, to: WebAuthSessionAPI.Type.self).init(
            url: url, callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            completion(Self.outcome(callbackURL: callbackURL, error: error))
        }
        session.presentationContextProvider = self
        // Private browser session: sharing Safari's cookies meant a signed-in
        // codegraff.com (or Google) account was reused silently, so signing
        // out and back in could never switch accounts.
        session.prefersEphemeralWebBrowserSession = true
        return session
    }

    /// For tests: a session as `start` configures it, without opening it.
    func preparedSession(url: URL, callbackScheme: String,
                         completion: @escaping (Outcome) -> Void = { _ in }) -> NSObject? {
        makeSession(url: url, callbackScheme: callbackScheme, completion: completion) as? NSObject
    }

    nonisolated static func outcome(callbackURL: URL?, error: Error?) -> Outcome {
        if let callbackURL { return .success(callbackURL) }
        if let error = error as NSError?, error.domain == sessionErrorDomain, error.code == canceledLoginCode {
            return .cancelled
        }
        return .failure(error?.localizedDescription ?? "Sign-in failed")
    }

    /// ASWebAuthenticationPresentationContextProviding.
    @objc(presentationAnchorForWebAuthenticationSession:)
    nonisolated func presentationAnchor(for session: NSObject) -> UIWindow {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let keyWindow = scenes.compactMap(\.keyWindow).first {
                return keyWindow
            }
            guard let scene = scenes.first else {
                preconditionFailure("Authentication requested without a connected window scene")
            }
            return UIWindow(windowScene: scene)
        }
    }
}

struct OrgPickerView: View {
    @Environment(AppModel.self) private var model
    let tokens: AuthTokens
    let orgs: [AuthOrg]
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Choose an organization")
                    .font(Theme.sans(16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                VStack(spacing: 8) {
                    ForEach(orgs) { org in
                        Button {
                            select(org)
                        } label: {
                            HStack {
                                Text(org.name)
                                    .font(Theme.sans(14, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textFaint)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(busy)
                    }
                }
                if let error {
                    Text(error).font(Theme.sans(12)).foregroundStyle(Theme.danger)
                }
                Button("Back") { model.signOut() }
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(24)
            .frame(maxWidth: 480)
        }
    }

    private func select(_ org: AuthOrg) {
        busy = true
        error = nil
        Task {
            do {
                try await model.selectOrg(org, tokens: tokens)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Compact CodeGraff-aligned mark used in the app's sign-in and session views.
struct HarnessMark: View {
    var color: Color = Theme.text

    var body: some View {
        HarnessMarkShape()
            .fill(color)
            .aspectRatio(1, contentMode: .fit)
    }
}
