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

    /// Where the stacked split's handle rests: the session given the screen (the list folded up), both
    /// panes, or the list given the screen (the session folded down).
    enum StackedPane: Equatable { case session, split, list }

    /// The stacked list's height while its handle is dragged: the resting height moved by the drag, never
    /// below nothing or above `extent`, the list's height with the whole screen.
    static func draggedListHeight(resting: CGFloat, drag: CGFloat, extent: CGFloat) -> CGFloat {
        min(max(resting + drag, 0), extent)
    }

    /// The list's height resting at `pane`: nothing, its height in the split (`open`), or all of it (`full`).
    static func stackedListHeight(for pane: StackedPane, open: CGFloat, full: CGFloat) -> CGFloat {
        switch pane {
        case .session: 0
        case .split: open
        case .list: max(full, open)
        }
    }

    /// Where a released drag settles: whichever of the three rests is nearest where the finger's momentum
    /// (`predicted`) carries the handle, so a short flick moves one step and a long one can go end to end.
    static func paneAfterDrag(resting: CGFloat, predicted: CGFloat, open: CGFloat, full: CGFloat) -> StackedPane {
        let end = draggedListHeight(resting: resting, drag: predicted, extent: max(full, open))
        let rests: [(StackedPane, CGFloat)] = [(.session, 0), (.split, open), (.list, max(full, open))]
        return rests.min { abs($0.1 - end) < abs($1.1 - end) }?.0 ?? .split
    }

    /// The pane actually shown. Typing in the session's composer gives the session the screen above the
    /// keyboard, whatever the handle's rest; the rest comes back when the composer lets the keyboard go
    /// (sending puts it away).
    static func shownPane(resting: StackedPane, composerFocused: Bool) -> StackedPane {
        composerFocused ? .session : resting
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

extension EnvironmentValues {
    /// Set inside a stacked split's session: its composer reports gaining and losing keyboard focus, so the
    /// split can give the session the screen while it types, and puts the keyboard away on send.
    @Entry var stackedComposerFocus: ((Bool) -> Void)? = nil
}

/// The list and the open session together, in the shape the arrangement asks for.
struct PhoneSplitContainer<List: View, Detail: View>: View {
    let arrangement: PhoneSplit.Arrangement
    /// The session the detail shows: opening one from a list that has the screen brings the split back.
    var selection: String? = nil
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail
    @State private var availableHeight: CGFloat = .infinity
    /// Stacked: where the handle rests (the session's screen, both, or the list's screen).
    @State private var pane: PhoneSplit.StackedPane = .split
    /// Stacked: the session's composer has the keyboard, so the session has the screen for now.
    @State private var composerFocused = false
    /// Stacked: how far the handle has been dragged, negative upward.
    @State private var drag: CGFloat = 0
    /// Stacked: this install is in the drag handle's "on" half (FeatureRollout). Read once per container.
    @State private var dragEnabled = FeatureRollout.isOn(.stackedSplitDrag)
    /// Stacked, "on" half: the one-time callout under the handle is showing.
    @State private var showDragOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The handle's height while it is the only way back to a folded pane, and with the list open.
    private static var handleFolded: CGFloat { 36 }
    private static var handleOpen: CGFloat { 18 }

    var body: some View {
        switch arrangement.axis {
        case .sideBySide:
            HStack(spacing: 0) {
                list.frame(width: arrangement.listExtent)
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(width: 0.5)
                detail.frame(maxWidth: .infinity)
            }
        case .stacked:
            stacked
        }
    }

    private var stacked: some View {
        // The list's height in the split (the keyboard can shrink it) and with the whole screen.
        let open = PhoneSplit.stackedListHeight(extent: arrangement.listExtent, available: availableHeight)
        let full = availableHeight.isFinite ? max(availableHeight - Self.handleFolded, open) : open
        let shown = PhoneSplit.shownPane(resting: dragEnabled ? pane : .split, composerFocused: composerFocused)
        let resting = PhoneSplit.stackedListHeight(for: shown, open: open, full: full)
        let height = dragEnabled ? PhoneSplit.draggedListHeight(resting: resting, drag: drag, extent: full) : resting
        // Mid-drag the handle is a plain grabber; at rest it shows the way back to a folded pane.
        let handleState: StackedSplitHandle.Mode
        switch shown {
        case _ where drag != 0: handleState = .split
        case .session: handleState = .sessionFull
        case .split: handleState = .split
        case .list: handleState = .listFull
        }
        return VStack(spacing: 0) {
            list.frame(height: height)
                .clipped()
                // The clip stops the list's own background at the split's top edge, so the status bar above
                // it showed the session's lighter color. While the list is on screen it colors the status bar.
                .background(height > 0 ? Theme.surface : Theme.bg, ignoresSafeAreaEdges: .top)
                .accessibilityHidden(height == 0)
            if dragEnabled {
                StackedSplitHandle(state: handleState, action: tapHandle)
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { value in
                                drag = value.translation.height
                                if showDragOnboarding { finishOnboarding() }
                            }
                            .onEnded { value in
                                let next = PhoneSplit.paneAfterDrag(
                                    resting: resting, predicted: value.predictedEndTranslation.height,
                                    open: open, full: full)
                                if composerFocused, next != .session { dismissKeyboard() }
                                setPane(next)
                            }
                    )
            } else {
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(height: 0.5)
            }
            detail.frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(shown == .list && drag == 0)
                .environment(\.stackedComposerFocus) { focused in
                    guard focused != composerFocused else { return }
                    withAnimation(reduceMotion ? nil : Motion.collapse) { composerFocused = focused }
                }
                .overlay(alignment: .top) {
                    if showDragOnboarding {
                        StackedDragOnboarding { finishOnboarding() }
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
        }
        // Above the keyboard: this is the height the two panes share right now.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .onChange(of: selection) { _, chat in
            // Picking a session from a list that has the screen opens it in the split.
            if chat != nil, pane == .list { setPane(.split) }
        }
        .onAppear {
            FeatureUsage.record(.splitShown, for: .stackedSplitDrag)
            if dragEnabled, !FeatureOnboarding.hasSeen(.stackedSplitDrag) {
                showDragOnboarding = true
                FeatureUsage.record(.onboardingShown, for: .stackedSplitDrag)
            }
        }
    }

    /// A tap on the handle: from the split it gives the session the screen; from either full screen it
    /// brings the split back. While the composer has the keyboard, the tap puts the keyboard away instead,
    /// which brings back whatever the handle rested at.
    private func tapHandle() {
        if composerFocused {
            dismissKeyboard()
        } else {
            setPane(pane == .split ? .session : .split)
        }
    }

    private func setPane(_ next: PhoneSplit.StackedPane) {
        if next != pane {
            let event: FeatureUsageEvent = switch next {
            case .session: .folded
            case .split: .unfolded
            case .list: .listExpanded
            }
            FeatureUsage.record(event, for: .stackedSplitDrag)
        }
        withAnimation(reduceMotion ? nil : Motion.collapse) {
            pane = next
            drag = 0
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The callout goes for good on "Got it" or on the first drag: either way the person has met the handle.
    private func finishOnboarding() {
        FeatureOnboarding.markSeen(.stackedSplitDrag)
        FeatureUsage.record(.onboardingDismissed, for: .stackedSplitDrag)
        withAnimation(reduceMotion ? nil : Motion.fadeQuick) { showDragOnboarding = false }
    }
}

/// The one-time introduction to the stacked split's handle, pointing up at it.
private struct StackedDragOnboarding: View {
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        VStack(spacing: 0) {
            // Points at the handle just above.
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.surfaceRaised)
                .offset(y: 3)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .offset(y: nudge ? -3 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New: full-screen sessions")
                        .font(Theme.sans(15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Drag the handle up to give this session the whole screen. Tap the split icon at the top to bring the list back.")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Got it", action: dismiss)
                        .font(Theme.sans(13, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 4)
                        .accessibilityIdentifier("stacked-drag-onboarding-dismiss")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stacked-drag-onboarding")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { nudge = true }
        }
    }
}

/// The stacked split's divider: a grabber to drag the list up out of the way (the session then fills the
/// screen), back down, or on down so the list fills the screen. With either pane folded it shows a split
/// icon that brings the split back.
private struct StackedSplitHandle: View {
    enum Mode { case split, sessionFull, listFull }
    let state: Mode
    let action: () -> Void

    private var folded: Bool { state != .split }

    private var label: String {
        switch state {
        case .split: "Hide the session list"
        case .sessionFull: "Show the session list"
        case .listFull: "Show the session"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if folded {
                    // Folded, this is the only way back to the other pane: make it plainly visible.
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
            .background(state == .listFull ? Theme.surface : Theme.bg)
            .overlay(alignment: state == .listFull ? .top : .bottom) {
                Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Drag up to give the session the whole screen, down to give the list the whole screen.")
        .accessibilityIdentifier("stacked-split-handle")
    }
}
