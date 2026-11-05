// Previews for each size class Home meets, including both iPhone Duo displays.
// The demo dataset stands in for a signed-in workspace.

#if DEBUG
import SwiftUI

@MainActor private func previewModel(pins: [String] = ["chat-veil", "chat-picker", "chat-deploy"]) -> AppModel {
    let model = AppModel()
    model.enterDemoMode()
    model.demoPinnedSessionIds = pins
    return model
}

/// iPhone Duo's outer display and any phone in portrait: compact width, regular height.
#Preview("Compact width (outer display)", traits: .fixedLayout(width: 410, height: 680)) {
    HomeView()
        .environment(previewModel())
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.verticalSizeClass, .regular)
        .harnessAppearance()
        .tint(Theme.text)
}

/// iPhone Duo's inner display and iPad: regular both ways, the list beside the session.
#Preview("Regular width and height (inner display)", traits: .fixedLayout(width: 669, height: 951)) {
    HomeView()
        .environment(previewModel())
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.verticalSizeClass, .regular)
        .harnessAppearance()
        .tint(Theme.text)
}

/// A Max-class iPhone in landscape: regular width, compact height, where two sessions can sit side by side.
#Preview("Regular width, compact height (landscape Max)", traits: .fixedLayout(width: 956, height: 440)) {
    HomeView()
        .environment(previewModel())
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.verticalSizeClass, .compact)
        .harnessAppearance()
        .tint(Theme.text)
}

/// Any phone in landscape: compact both ways.
#Preview("Compact width and height (landscape)", traits: .fixedLayout(width: 852, height: 393)) {
    HomeView()
        .environment(previewModel(pins: []))
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.verticalSizeClass, .compact)
        .harnessAppearance()
        .tint(Theme.text)
}
#endif
