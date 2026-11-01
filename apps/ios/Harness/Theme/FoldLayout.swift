// iPhone Duo: lay the window out around the fold and keep content clear of
// hardware that covers it.
//
// The fold is a `.division` reserved region. It is active only while the
// device is partly folded; flat or closed it reports nothing (by default). Its
// frame is 40pt across, a 20pt margin either side of a zero-width fold line.
// Folded like a book the division runs top to bottom, so the session list and
// the open session sit side by side, split on the fold. Folded like a laptop it
// runs across, so they stack, the session above (its composer, and the keyboard
// below it, on the lower half) and the list below.
//
// `.occlusion` regions are areas covered by hardware, such as the camera while
// it is in use. Content that overlaps an active one is padded away from it. The
// status bar strip is an occlusion region too, but the safe area already keeps
// content out of it, so it never overlaps the view's own bounds.
//
// The pure parts (`FoldSplit`, `OcclusionInsets`) are tested without a device.
// Reading the regions needs the iOS 27.1 SDK (`HINGE_API`, see HingeRecede).

import SwiftUI

/// How the fold divides the window, if it does.
enum FoldSplit: Equatable {
    /// No active fold: one region (flat, closed, or not a foldable).
    case none
    /// Book pose: the fold runs top to bottom. `leading` is the width before the division, `gap` its width.
    case sideBySide(leading: CGFloat, gap: CGFloat)
    /// Laptop pose: the fold runs across. `top` is the height above the division, `gap` its height.
    case stacked(top: CGFloat, gap: CGFloat)

    /// From the first active division's frame, in the same coordinate space as `size`.
    static func from(division frame: CGRect?, in size: CGSize) -> FoldSplit {
        guard let frame, !frame.isNull,
              frame.maxX >= 0, frame.minX <= size.width, frame.maxY >= 0, frame.minY <= size.height
        else { return .none }
        if frame.height > frame.width {
            let leading = min(max(frame.minX, 0), size.width)
            return .sideBySide(leading: leading, gap: min(frame.width, size.width - leading))
        } else {
            let top = min(max(frame.minY, 0), size.height)
            return .stacked(top: top, gap: min(frame.height, size.height - top))
        }
    }
}

/// What a session shown above the fold in laptop pose needs from Home. The system bar there shares its row
/// with the status bar cluster, so a bar-hosted title ran out of room and slid under the back arrow; the
/// session draws its own header strip below the status bar instead, with its own back button.
struct FoldPaneHeader {
    /// Bring the session list over the upper half. Set while the keyboard covers the list on the lower half.
    var showList: (() -> Void)?
}

extension EnvironmentValues {
    /// Set on a session above the fold in laptop pose; nil everywhere else.
    @Entry var foldPaneHeader: FoldPaneHeader? = nil
    /// Set above the fold in laptop pose: the composer reports keyboard focus, so Home knows the keyboard
    /// covers the list on the lower half.
    @Entry var foldComposerFocus: ((Bool) -> Void)? = nil
}

/// Where the session list's search field goes. In laptop pose the floating field covered a row of the
/// half-height list, so it moves into the bar like the phone split's. Book pose keeps it floating: the list
/// column is full height, and a field in the column's bar sat over the list's title.
enum SessionSearchPlacement {
    static func inBar(phoneSplit: Bool, fold: FoldSplit) -> Bool {
        if case .stacked = fold { return true }
        return phoneSplit
    }
}

/// Whether Home puts the session list beside the open session.
enum HomeColumns {
    /// Regular width shows the list beside the session (iPad, a Max in landscape), except on iPhone Duo's inner
    /// display lying flat: an iPhone window regular both ways is that display, and flat it is the ordinary
    /// one-column iPhone app. Folded like a book, the list and the session take either side of the fold.
    /// `phone` is the device idiom; it is the only signal the TestFlight build has, since its SDK predates
    /// the hinge API and its fold is always `.none`.
    static func listBesideSession(regularWidth: Bool, regularHeight: Bool, phone: Bool, fold: FoldSplit) -> Bool {
        guard regularWidth else { return false }
        if case .sideBySide = fold { return true }
        return !(phone && regularHeight)
    }
}

/// Padding that keeps content clear of active occlusion regions inside the view.
enum OcclusionInsets {
    /// Each region that overlaps the bounds pushes content in from the edge it is nearest, by as far as it
    /// reaches. Regions outside the bounds (already in the safe area) add nothing.
    static func insets(for frames: [CGRect], in size: CGSize) -> EdgeInsets {
        var insets = EdgeInsets()
        let bounds = CGRect(origin: .zero, size: size)
        for frame in frames {
            let overlap = frame.intersection(bounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let top = overlap.maxY, bottom = size.height - overlap.minY
            let leading = overlap.maxX, trailing = size.width - overlap.minX
            switch min(top, bottom, leading, trailing) {
            case top: insets.top = max(insets.top, top)
            case bottom: insets.bottom = max(insets.bottom, bottom)
            case leading: insets.leading = max(insets.leading, leading)
            default: insets.trailing = max(insets.trailing, trailing)
            }
        }
        return insets
    }
}

extension View {
    /// Report how the fold divides this view (`.none` until the iOS 27.1 SDK, and on every device without one).
    func onFoldChange(_ action: @escaping (FoldSplit) -> Void) -> some View {
        modifier(FoldReader(action: action))
    }

    /// Pad this view's content away from hardware that covers it (iPhone Duo's camera while it is in use).
    func avoidingOcclusions() -> some View {
        modifier(OcclusionAvoider())
    }
}

private struct FoldReader: ViewModifier {
    let action: (FoldSplit) -> Void

    func body(content: Content) -> some View {
        #if HINGE_API
        if #available(iOS 27.1, *) {
            content.onGeometryChange(for: FoldSplit.self) { proxy in
                FoldSplit.from(division: proxy.reservedRegions(kind: .division).first?.frame, in: proxy.size)
            } action: { action($0) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct OcclusionAvoider: ViewModifier {
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        #if HINGE_API
        if #available(iOS 27.1, *) {
            content
                .safeAreaPadding(insets)
                .onGeometryChange(for: EdgeInsets.self) { proxy in
                    OcclusionInsets.insets(for: proxy.reservedRegions(kind: .occlusion).map(\.frame), in: proxy.size)
                } action: { insets = $0 }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
