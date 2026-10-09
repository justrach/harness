import SwiftUI
import WebKit

/// OpenAI's sign-in page in an in-app browser that stops at the sign-in's
/// loopback redirect (which can't load on a phone) and hands that address
/// over instead of navigating. Cookies persist, so the next reconnect is
/// usually one tap.
struct ChatGPTSignInBrowser: View {
    let signIn: AgentReauthentication.BrowserSignIn
    let onRedirect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInWebView(signIn: signIn) { redirect in
                onRedirect(redirect)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in with ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    let signIn: AgentReauthentication.BrowserSignIn
    let onRedirect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(signIn: signIn, onRedirect: onRedirect) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.accessibilityIdentifier = "chatgpt-sign-in-browser"
        view.load(URLRequest(url: signIn.url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let signIn: AgentReauthentication.BrowserSignIn
        let onRedirect: (String) -> Void
        private var handed = false

        init(signIn: AgentReauthentication.BrowserSignIn, onRedirect: @escaping (String) -> Void) {
            self.signIn = signIn
            self.onRedirect = onRedirect
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Server redirects pass through here too, so the loopback address is
            // caught before the page tries (and fails) to load it.
            guard let url = action.request.url, signIn.isCallback(url) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard !handed else { return }
            handed = true
            onRedirect(url.absoluteString)
        }

        /// Sign-in popups (Apple, Microsoft) open in this same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
    }
}
