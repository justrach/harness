// Split view on iPhone, opt-in. iPad already shows the session list next to the open session; this lets an
// iPhone do the same when there is room, in one of two shapes:
//   - side by side: the list on the left, the open session on the right (landscape, or a wide fold);
//   - stacked: the list on top, the open session below (portrait, tall screens).
// Off by default. When the shape does not fit the window, the normal single stack is used, so turning it on
// never squeezes a phone-sized screen. The rule is pure so it is tested without UI.

import SwiftUI

enum PhoneSplit: String, CaseIterable, Identifiable {
    case off
    case sideBySide
    case stacked

    var id: String { rawValue }
    static let storageKey = "phoneSplit"

    var label: String {
        switch self {
        case .off: "Off"
        case .sideBySide: "Side by side"
        case .stacked: "Stacked"
        }
    }

    /// The shape a window gets, and the extent of the list pane along the split axis.
    struct Arrangement: Equatable {
        enum Axis: Equatable { case sideBySide, stacked }
        var axis: Axis
        var listExtent: CGFloat
    }

    /// Room each shape needs before it is used: below this the single stack is kinder than two cramped panes.
    static let minimumWidthSideBySide: CGFloat = 600
    static let minimumHeightStacked: CGFloat = 600
    /// A pane never gets so small it cannot be read, nor so large the session loses its room.
    static let sideListRange: ClosedRange<CGFloat> = 280...380
    static let stackedListRange: ClosedRange<CGFloat> = 240...420

    static func arrangement(mode: PhoneSplit, in size: CGSize) -> Arrangement? {
        switch mode {
        case .off:
            return nil
        case .sideBySide:
            guard size.width >= minimumWidthSideBySide else { return nil }
            return Arrangement(axis: .sideBySide, listExtent: clamp(size.width * 0.38, to: sideListRange))
        case .stacked:
            guard size.height >= minimumHeightStacked else { return nil }
            return Arrangement(axis: .stacked, listExtent: clamp(size.height * 0.45, to: stackedListRange))
        }
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The list and the open session together, in the shape the arrangement asks for.
struct PhoneSplitContainer<List: View, Detail: View>: View {
    let arrangement: PhoneSplit.Arrangement
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        switch arrangement.axis {
        case .sideBySide:
            HStack(spacing: 0) {
                list.frame(width: arrangement.listExtent)
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(width: 0.5)
                detail.frame(maxWidth: .infinity)
            }
        case .stacked:
            VStack(spacing: 0) {
                list.frame(height: arrangement.listExtent)
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(height: 0.5)
                detail.frame(maxHeight: .infinity)
            }
        }
    }
}
