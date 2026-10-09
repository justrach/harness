// Session notifications, like the desktop's: a run finished, a session is
// waiting on you, a run failed. The edge decides and sends them over APNs
// (edge/src/push-notify.ts); this asks for permission, hands the edge this
// phone's token and choices, stays quiet while the app is open (the desktop's
// "only in the background"), and opens the session a notification is about.

import UIKit
import UserNotifications

@MainActor
final class PushNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotifications()

    enum Kind: String, CaseIterable, Identifiable {
        case done, input, failed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .done: "Run finished"
            case .input: "Waiting on your input"
            case .failed: "Run failed"
            }
        }
    }

    private weak var model: AppModel?
    private var token: String?
    /// A tapped notification's chat, until a signed-in model can show it.
    private var pendingChat: String?

    private let defaults = UserDefaults.standard
    private static let enabledKey = "notifications.enabled"
    private static let askedKey = "notifications.asked"

    // MARK: Choices

    /// The master switch (on unless turned off here; the system permission is separate).
    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            Task { await self.sync() }
        }
    }

    func isOn(_ kind: Kind) -> Bool {
        defaults.object(forKey: "notifications.\(kind.rawValue)") as? Bool ?? true
    }

    func set(_ kind: Kind, _ on: Bool) {
        defaults.set(on, forKey: "notifications.\(kind.rawValue)")
        Task { await self.sync() }
    }

    private var prefs: [String: Bool] {
        Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, isOn($0)) })
    }

    // MARK: Lifecycle

    /// At launch, before it finishes: route taps (a cold launch's included).
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Signed in (or launched signed in): re-register if already allowed.
    /// Tokens can change between launches; the edge keeps the latest.
    func signedIn(model: AppModel) {
        self.model = model
        if let chat = pendingChat {
            pendingChat = nil
            model.launchRoute = .chat(chat)
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if Self.allowed(settings.authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// The first time a session is started from this phone: the moment the
    /// ask makes sense ("tell me when it's done").
    func askAfterFirstSession() {
        guard model?.demo == nil, enabled, !defaults.bool(forKey: Self.askedKey) else { return }
        defaults.set(true, forKey: Self.askedKey)
        Task { _ = await self.requestPermission() }
    }

    /// Ask the system (once; later it's the Settings app's call).
    @discardableResult
    func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let granted: Bool
        if status == .notDetermined {
            granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        } else {
            granted = Self.allowed(status)
        }
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Signing out: this phone stops getting the account's notifications.
    /// Called while the sign-in is still usable, so the edge can be told.
    func signingOut(config: AppConfig?) {
        token = nil
        model = nil
        if let config {
            Task.detached { _ = await Self.send(config.pushTargetRequest(register: nil)) }
        }
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    // MARK: Token

    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await sync() }
    }

    func didFailToRegister(_ error: Error) {
        NSLog("push registration failed: \(error)")
    }

    /// Tell the edge what this phone wants now (or that it wants nothing).
    private func sync() async {
        guard let model, model.demo == nil, let config = model.pushConfig else { return }
        let request: URLRequest?
        if enabled, let token {
            request = await config.pushTargetRequest(register: PushRegistration(
                token: token, environment: Self.apnsEnvironment, prefs: prefs))
        } else if !enabled {
            request = await config.pushTargetRequest(register: nil)
        } else {
            return
        }
        if !(await Self.send(request)) { NSLog("push target sync failed") }
    }

    private nonisolated static func send(_ request: URLRequest?) async -> Bool {
        guard let request,
              let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Which APNs this build's tokens belong to: development-signed builds
    /// (Xcode) say so in their provisioning profile; App Store / TestFlight
    /// builds carry none and are production.
    static let apnsEnvironment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1)
        else { return "production" }
        return text.range(of: "<key>aps-environment</key>\\s*<string>development</string>",
                          options: .regularExpression) != nil ? "sandbox" : "production"
        #endif
    }()

    // MARK: Delivery

    // Completion-handler forms on the main queue: the async variants complete
    // off the main thread, which UIKit asserts on when a tap opens a view.

    /// In the app: no banner (the list and the session already show it).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    /// Tapped: open that session. Home picks the route up once it is on
    /// screen, so a cold launch lands there too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let chatId = response.notification.request.content.userInfo["chatId"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let chatId, !chatId.isEmpty { self.open(chatId) }
            }
            completionHandler()
        }
    }
}

extension PushNotifications {
    /// Home picks the route up once it is on screen, so a cold launch lands there too.
    fileprivate func open(_ chatId: String) {
        if let model { model.launchRoute = .chat(chatId) } else { pendingChat = chatId }
    }
}

/// A phone's APNs registration as the edge stores it (POST /registry/:org/push-target).
struct PushRegistration: Encodable {
    let token: String
    let environment: String
    let prefs: [String: Bool]
}

/// The UIKit hooks SwiftUI has no other way to receive: the APNs token and
/// the notification center delegate installed before launch finishes.
final class HarnessAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated { PushNotifications.shared.install() }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushNotifications.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushNotifications.shared.didFailToRegister(error) }
    }
}
