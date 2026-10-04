// Split screen on a Max iPhone: two sessions side by side, each closable. Only a phone whose window is regular
// width has the room (a Pro Max or Plus in landscape); every other iPhone keeps the single stack, and iPad keeps
// its sidebar. Two panes at most: three or four would leave each one too short to read or type in.
//
// One keyboard serves the screen: the pane being typed in keeps its composer above it and the other pane simply
// has less height, the same as a single session. Adding a pane never asks which session — it opens the most
// recently used one that is not already on screen — and the pane model is pure so it is tested without UI.

import SwiftUI

enum SplitScreen {
    static let maxPanes = 2

    /// A Max-class iPhone: a phone whose window is regular width. iPad is excluded on purpose.
    static func isAvailable(idiom: UIUserInterfaceIdiom, sizeClass: UserInterfaceSizeClass?) -> Bool {
        idiom == .phone && sizeClass == .regular
    }

    /// The session a new pane opens: the most recently used one that is not already on screen.
    static func mostRecent(excluding open: Set<String>, in chats: [Chat]) -> String? {
        sortActive(chats).first { !open.contains($0.id) }?.id
    }
}

/// Which sessions the panes show. `primary` is the pane the navigation stack drives.
struct SplitPanes: Equatable {
    enum Pane { case primary, secondary }

    var primary: String?
    var secondary: String?

    var open: Set<String> { Set([primary, secondary].compactMap { $0 }) }
    var count: Int { (primary == nil ? 0 : 1) + (secondary == nil ? 0 : 1) }
    var canAdd: Bool { primary != nil && secondary == nil && count < SplitScreen.maxPanes }

    /// Adds a second pane showing `id`. Does nothing when full, empty, or `id` is already shown.
    mutating func add(_ id: String?) {
        guard canAdd, let id, !open.contains(id) else { return }
        secondary = id
    }

    /// Closing the first pane promotes the second into its place, so one pane is always the primary.
    mutating func close(_ pane: Pane) {
        switch pane {
        case .secondary:
            secondary = nil
        case .primary:
            primary = secondary
            secondary = nil
        }
    }

    /// A session picked from the list replaces the first pane. If it is already the second pane the two swap,
    /// so a session is never on screen twice.
    mutating func openFromList(_ id: String) {
        if id == secondary { secondary = primary }
        primary = id
    }
}

/// What a session's header offers while split screen is available: open another session beside it, and close it.
struct SplitScreenControls {
    var openBeside: (() -> Void)?
    var close: (() -> Void)?
    /// Show or hide the session list (one pane only; with two panes the list is out of the way).
    var toggleList: (() -> Void)?
}

extension EnvironmentValues {
    /// Set per pane by Home; nil everywhere split screen is not available.
    @Entry var splitScreen: SplitScreenControls? = nil
}
