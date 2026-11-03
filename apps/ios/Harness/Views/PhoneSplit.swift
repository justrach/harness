// Split view on iPhone, opt-in. iPad already shows the session list next to the open session; this lets an
// iPhone do the same when there is room: the list on the left, the open session on the right (landscape, or a
// wide fold). Off by default. When the window is too narrow, the normal single stack is used, so turning it on
// never squeezes a phone-sized screen. The rule is pure so it is tested without UI.

import SwiftUI

enum PhoneSplit: String, CaseIterable, Identifiable {
    case off
    /// Side by side wherever the window has room for it, nothing otherwise: no shape to choose, no cramped
    /// panes. A Pro Max in landscape already gets the iPad-style sidebar from its regular width, so Auto
    /// changes nothing there; it is for the iPhones that stay compact in landscape.
    case auto
    case sideBySide

    var id: String { rawValue }
    static let storageKey = "phoneSplit"

    var label: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .sideBySide: "Side by side"
        }
    }

    /// The choice a stored value stands for. "stacked" (the list above the session) was removed; someone who
    /// had picked it wanted a split, so it becomes Auto rather than Off. Anything else unknown is Off.
    static func stored(_ raw: String) -> PhoneSplit {
        if raw == removedStacked { return .auto }
        return PhoneSplit(rawValue: raw) ?? .off
    }

    private static let removedStacked = "stacked"

    /// Rewrites a saved "stacked" once, so Settings shows Auto picked, and drops the removed shape's drag
    /// handle keys (its rollout pin, usage counts and one-time introduction).
    static func migrateStored(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: storageKey) == removedStacked {
            defaults.set(auto.rawValue, forKey: storageKey)
        }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("usage.stackedSplitDrag.") || key == "rollout.stackedSplitDrag"
            || key == "onboarding.stackedSplitDrag.seen" {
            defaults.removeObject(forKey: key)
        }
    }

    /// The extent of the list pane beside the session.
    struct Arrangement: Equatable {
        var listExtent: CGFloat
    }

    /// Room the split needs before it is used: below this the single stack is kinder than two cramped panes.
    static let minimumWidthSideBySide: CGFloat = 600
    /// A pane never gets so small it cannot be read, nor so large the session loses its room.
    static let sideListRange: ClosedRange<CGFloat> = 280...380
    /// The window size the split is chosen from. A phone's window only gets shorter at the same width when the
    /// keyboard comes up (rotating or unfolding changes the width), so a shorter measurement at an unchanged
    /// width keeps the previous height: the keyboard never reshapes the layout under the person typing.
    static func layoutSize(previous: CGSize, measured: CGSize) -> CGSize {
        guard measured.width == previous.width, measured.height < previous.height else { return measured }
        return previous
    }

    static func arrangement(mode: PhoneSplit, in size: CGSize) -> Arrangement? {
        switch mode {
        case .off:
            return nil
        case .auto, .sideBySide:
            guard size.width >= minimumWidthSideBySide else { return nil }
            return Arrangement(listExtent: clamp(size.width * 0.38, to: sideListRange))
        }
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The list and the open session side by side.
struct PhoneSplitContainer<List: View, Detail: View>: View {
    let arrangement: PhoneSplit.Arrangement
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: arrangement.listExtent)
            // The session's lifted page rounds where it meets the list, in place of a rule (ContentPlane).
            detail.frame(maxWidth: .infinity)
                .seam(.leading, chrome: Theme.surface)
        }
    }
}
