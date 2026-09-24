// Sign-in with CodeGraff OAuth and PKCE. The edge verifies the OIDC identity.
// The harness mark on black, one white button — the old mobile app's Gate.
//
// Endpoints are fixed to production (the old app's rule: mobile always talks
// to prod; a stale override once broke sign-in in the worst ghost way).

import AuthenticationServices
import CryptoKit
import SwiftUI

/// Production cloud endpoints — mirrors edge/wrangler.jsonc.
enum Endpoints {
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
    @State private var busy = false
    @State private var error: String?
    @State private var authSession = AuthSessionCoordinator()

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
                        signIn()
                    } label: {
                        Group {
                            if busy {
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
                    .disabled(busy)
                    .opacity(busy ? 0.6 : 1)

                    if let error {
                        Text(error)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
        }
    }

    /// CodeGraff browser sign-in → Harness callback → edge exchange with PKCE.
    private func signIn() {
        busy = true
        error = nil
        let state = UUID().uuidString
        let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        authSession.start(url: Endpoints.authorizeURL(state: state, challenge: challenge),
                          callbackScheme: Endpoints.callbackScheme) { result in
            Task { @MainActor in
                switch result {
                case .cancelled:
                    busy = false
                case .failure(let message):
                    busy = false
                    error = message
                case .success(let callbackURL):
                    let params = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems ?? []
                    let code = params.first { $0.name == "code" }?.value
                    let cbState = params.first { $0.name == "state" }?.value
                    guard let code, cbState == state else {
                        busy = false
                        error = "Callback missing code or state mismatch"
                        return
                    }
                    do {
                        try await model.signIn(edgeURL: Endpoints.edgeURL, code: code,
                                               codeVerifier: verifier,
                                               redirectURI: Endpoints.redirectURI,
                                               nonce: state)
                    } catch {
                        self.error = error.localizedDescription
                    }
                    busy = false
                }
            }
        }
    }
}

// MARK: - Auth session plumbing

/// Wraps ASWebAuthenticationSession with a presentation anchor.
@MainActor
final class AuthSessionCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Outcome {
        case success(URL)
        case cancelled
        case failure(String)
    }

    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String, completion: @escaping (Outcome) -> Void) {
        let session = ASWebAuthenticationSession(url: url,
                                                 callbackURLScheme: callbackScheme) { callbackURL, error in
            if let callbackURL {
                completion(.success(callbackURL))
            } else if let error = error as? ASWebAuthenticationSessionError,
                      error.code == .canceledLogin {
                completion(.cancelled)
            } else {
                completion(.failure(error?.localizedDescription ?? "Sign-in failed"))
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let keyWindow = scenes.compactMap(\.keyWindow).first {
                return keyWindow
            }
            guard let scene = scenes.first else {
                preconditionFailure("Authentication requested without a connected window scene")
            }
            return ASPresentationAnchor(windowScene: scene)
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

struct HarnessMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var ring = Path()
        ring.move(to: CGPoint(x: 778, y: 275))
        ring.addCurve(to: CGPoint(x: 418, y: 205), control1: CGPoint(x: 678, y: 180), control2: CGPoint(x: 545, y: 160))
        ring.addCurve(to: CGPoint(x: 222, y: 526), control1: CGPoint(x: 272, y: 255), control2: CGPoint(x: 212, y: 389))
        ring.addCurve(to: CGPoint(x: 531, y: 814), control1: CGPoint(x: 234, y: 700), control2: CGPoint(x: 371, y: 812))
        ring.addCurve(to: CGPoint(x: 794, y: 722), control1: CGPoint(x: 650, y: 817), control2: CGPoint(x: 733, y: 772))
        path.addPath(ring.strokedPath(StrokeStyle(lineWidth: 108, lineCap: .round)))

        for points in [
            [CGPoint(x: 456, y: 457), CGPoint(x: 383, y: 500), CGPoint(x: 456, y: 543)],
            [CGPoint(x: 536, y: 437), CGPoint(x: 493, y: 563)],
            [CGPoint(x: 578, y: 457), CGPoint(x: 651, y: 500), CGPoint(x: 578, y: 543)],
        ] {
            var glyph = Path()
            glyph.addLines(points)
            path.addPath(glyph.strokedPath(StrokeStyle(lineWidth: 31, lineCap: .round, lineJoin: .round)))
        }

        let pixels: [(CGFloat, CGFloat, CGFloat)] = [
            (802, 455, 27), (849, 495, 38), (790, 552, 48),
            (860, 574, 23), (823, 630, 34), (893, 662, 18),
        ]
        for (x, y, size) in pixels {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: size, height: size),
                                cornerSize: CGSize(width: size / 7, height: size / 7))
        }

        let scale = min(rect.width, rect.height) / 1000
        let dx = rect.minX + (rect.width - 1000 * scale) / 2
        let dy = rect.minY + (rect.height - 1000 * scale) / 2
        return path.applying(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}
