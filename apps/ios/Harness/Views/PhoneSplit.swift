// Split view on iPhone, opt-in. iPad already shows the session list next to the open session; this lets an
// iPhone do the same when there is room, in one of two shapes:
//   - side by side: the list on the left, the open session on the right (landscape, or a wide fold);
//   - stacked: the list on top, the open session below (portrait, tall screens).
// Off by default. When the shape does not fit the window, the normal single stack is used, so turning it on
// never squeezes a phone-sized screen. The rule is pure so it is tested without UI.

import SwiftUI

enum PhoneSplit: String, CaseIterable, Identifiable {
    case off
    /// Side by side wherever the window has room for it, nothing otherwise: no shape to choose, no cramped
    /// panes. Stacked is never automatic. A Pro Max in landscape already gets the iPad-style sidebar from its
    /// regular width, so Auto changes nothing there; it is for the iPhones that stay compact in landscape.
    case auto
    case sideBySide
    case stacked

    var id: String { rawValue }
    static let storageKey = "phoneSplit"

    var label: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
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
    /// The window size a shape is chosen from. A phone's window only gets shorter at the same width when the
    /// keyboard comes up (rotating or unfolding changes the width), so a shorter measurement at an unchanged
    /// width keeps the previous height. Otherwise the keyboard dropped a stacked split below its minimum the
    /// moment someone tapped the composer: the single stack replaced the split, the session was rebuilt, its
    /// composer left the window and the keyboard went with it.
    static func layoutSize(previous: CGSize, measured: CGSize) -> CGSize {
        guard measured.width == previous.width, measured.height < previous.height else { return measured }
        return previous
    }

    /// Height the session keeps below a stacked list: its header, a few rows and the composer.
    static let stackedSessionMinimum: CGFloat = 320

    /// The stacked list's height in a pane that is `available` tall right now. The arrangement's extent is
    /// fixed from the window measured without the keyboard; when the keyboard takes room, the list gives it up
    /// so the session keeps `stackedSessionMinimum`. Squeezed below that, the composer lost focus as soon as
    /// it gained it and typing never worked.
    static func stackedListHeight(extent: CGFloat, available: CGFloat) -> CGFloat {
        max(min(extent, available - stackedSessionMinimum), 0)
    }

    static func arrangement(mode: PhoneSplit, in size: CGSize) -> Arrangement? {
        switch mode {
        case .off:
            return nil
        case .auto, .sideBySide:
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
    @State private var availableHeight: CGFloat = .infinity

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
                list.frame(height: PhoneSplit.stackedListHeight(extent: arrangement.listExtent,
                                                                available: availableHeight))
                    .clipped()
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(height: 0.5)
                detail.frame(maxHeight: .infinity)
            }
            // Above the keyboard: this is the height the two panes share right now.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        }
    }
}
