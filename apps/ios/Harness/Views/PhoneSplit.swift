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

    /// The stacked list's height while its handle is dragged: the resting height moved by the drag, never
    /// below nothing or above the arrangement's extent.
    static func draggedListHeight(resting: CGFloat, drag: CGFloat, extent: CGFloat) -> CGFloat {
        min(max(resting + drag, 0), extent)
    }

    /// Where a released drag settles: folded away (the session gets the whole screen) when it would end
    /// above half the list's extent, open otherwise. `predicted` is where the finger's momentum carries it,
    /// so a short flick up folds and a short flick down opens.
    static func foldsAfterDrag(resting: CGFloat, predicted: CGFloat, extent: CGFloat) -> Bool {
        draggedListHeight(resting: resting, drag: predicted, extent: extent) < extent / 2
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
    /// Stacked: the list folded away under its handle, so the session has the whole screen.
    @State private var listFolded = false
    /// Stacked: how far the handle has been dragged, negative upward.
    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch arrangement.axis {
        case .sideBySide:
            HStack(spacing: 0) {
                list.frame(width: arrangement.listExtent)
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(width: 0.5)
                detail.frame(maxWidth: .infinity)
            }
        case .stacked:
            // The list's height when open (the keyboard can shrink it), and where it rests now.
            let open = PhoneSplit.stackedListHeight(extent: arrangement.listExtent, available: availableHeight)
            let resting = listFolded ? 0 : open
            let height = PhoneSplit.draggedListHeight(resting: resting, drag: drag, extent: open)
            VStack(spacing: 0) {
                list.frame(height: height)
                    .clipped()
                    .accessibilityHidden(height == 0)
                StackedSplitHandle(folded: listFolded && drag == 0) { setFolded(!listFolded) }
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { drag = $0.translation.height }
                            .onEnded { value in
                                setFolded(PhoneSplit.foldsAfterDrag(
                                    resting: resting, predicted: value.predictedEndTranslation.height,
                                    extent: open))
                            }
                    )
                detail.frame(maxHeight: .infinity)
            }
            // Above the keyboard: this is the height the two panes share right now.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        }
    }

    private func setFolded(_ folded: Bool) {
        withAnimation(reduceMotion ? nil : Motion.collapse) {
            listFolded = folded
            drag = 0
        }
    }
}

/// The stacked split's divider: a grabber to drag the list up out of the way (the session then fills the
/// screen) or back down. Folded, it stays at the top with a visible split icon that brings the list back.
private struct StackedSplitHandle: View {
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                if folded {
                    // Folded, this is the only way back to the list: make it plainly visible.
                    Image(systemName: "rectangle.split.1x2")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Capsule()
                    .fill(Theme.textFaint.opacity(0.55))
                    .frame(width: 36, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: folded ? 36 : 18)
            .contentShape(Rectangle())
            .background(Theme.bg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folded ? "Show the session list" : "Hide the session list")
        .accessibilityHint("Drag up to give the session the whole screen, down to bring the list back.")
        .accessibilityIdentifier("stacked-split-handle")
    }
}
