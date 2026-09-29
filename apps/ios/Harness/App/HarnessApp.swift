// Harness for iOS — a viewport onto the harness mesh. The phone is a peer
// device: it joins the workspace and session doc rooms and drives remote
// engines through the durable command queue.

import SwiftUI

@main
struct HarnessApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .harnessAppearance()
                // Monochrome controls: glass buttons, toolbar icons, and
                // toggles render in text color like the desktop — accent
                // stays paint for status/markdown, never chrome.
                .tint(Theme.text)
                .background(Theme.bg)
                .onAppear {
                    if let scene = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene }).first {
                        ThemeStore.shared.attach(to: scene)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        model.flushDocs()
                    } else if phase == .active {
                        ThemeStore.shared.refreshSystemAppearance()
                        // Suspension kills sockets without running any
                        // failure path — without this kick the workspace
                        // room stays dead after foregrounding while chat
                        // views reconnect on open (frozen sidebar/Working
                        // indicators against live transcripts, 2026-08-04).
                        model.foregrounded()
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut:
                SignInView()
            case .pickingOrg(let tokens, let orgs):
                OrgPickerView(tokens: tokens, orgs: orgs)
            case .ready:
                HomeView()
                    .task {
                        // Sampled, not observed: the snapshots read live
                        // transcripts, so observing them re-rendered the root
                        // on every streamed token. A lock-screen status only
                        // needs a couple of seconds' resolution.
                        while !Task.isCancelled {
                            model.liveActivities.sync(model.liveActivitySnapshots)
                            try? await Task.sleep(for: .seconds(2))
                        }
                    }
            }
        }
        .task { model.restore() }
        .onOpenURL { model.openDeepLink($0) }
    }
}
