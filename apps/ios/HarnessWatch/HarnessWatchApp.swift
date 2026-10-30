// Harness for Apple Watch (#322): tap, talk, stop, then send what you said to
// a Harness chat. The paired iPhone delivers it like any message.

import SwiftUI

@main
struct HarnessWatchApp: App {
    @State private var store = WatchStore.shared
    @State private var recorder = Recorder()
    /// Set by the complication's link: start recording on arrival.
    @State private var dictateRequest = 0

    init() {
        WatchStore.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            HomeView(dictateRequest: dictateRequest)
                .environment(store)
                .environment(recorder)
                .onOpenURL { url in
                    if url == WatchLink.dictateURL { dictateRequest += 1 }
                }
                .task {
                    // Simulator rig: arrive recording, as the complication does.
                    if ProcessInfo.processInfo.arguments.contains("-watchDictate") { dictateRequest += 1 }
                }
        }
    }
}
