// Foldable phones: the system's own UI reacts to the hinge as it moves (the
// wallpaper zooms with the angle). Without that an app holds one flat frame
// until the inner display cuts to black. This recedes the whole app while the
// hinge is closing and brings it back as it opens; once the hinge stops moving
// the app settles to normal, so the book and laptop poses look like any other.
// No hinge, no effect.
//
// The hinge API arrived in the iOS 27.1 SDK. HINGE_API is set by the project
// for that SDK and later (see SWIFT_ACTIVE_COMPILATION_CONDITIONS), so older
// Xcodes, like the one the TestFlight workflow archives with, skip this file's
// hinge code instead of failing to compile.

import SwiftUI

extension View {
    func hingeRecede() -> some View { modifier(HingeRecedeModifier()) }
}

/// How far the hinge is into closing: 0 at `startDegrees` and wider, 1 at
/// `endDegrees` and narrower.
enum HingeClosing {
    static let startDegrees = 110.0
    static let endDegrees = 20.0

    static func progress(degrees: Double) -> Double {
        let t = min(max((startDegrees - degrees) / (startDegrees - endDegrees), 0), 1)
        return t * t * (3 - 2 * t)  // smoothstep: no snap at either end
    }
}

#if HINGE_API

/// The hinge stopped moving: how long before the app returns to normal.
private let hingeSettleDelay: Duration = .milliseconds(450)

private struct HingeRecedeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            HingeRecede(content: content)
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct HingeRecede<Content: View>: View {
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hingeClosing: Double = 0
    @State private var settle: Task<Void, Never>?

    /// Only the inner display (regular width) recedes. A closed hinge is the
    /// normal state of the outer display, which must look like any phone.
    private var closing: Double { horizontalSizeClass == .regular ? hingeClosing : 0 }

    var body: some View {
        content
            .scaleEffect(1 - 0.06 * closing)
            .clipShape(RoundedRectangle(cornerRadius: 40 * closing, style: .continuous))
            .overlay {
                if closing > 0 { Color.black.opacity(0.4 * closing).allowsHitTesting(false) }
            }
            .onHingeChange { _, new in hingeChanged(new.hinge) }
    }

    private func hingeChanged(_ hinge: DeviceHinge?) {
        settle?.cancel()
        guard let hinge, hinge.status != .fullyOpen else { return animate(to: 0) }
        // Angle updates are sparse, so ease between them.
        animate(to: hinge.status == .closed ? 1 : HingeClosing.progress(degrees: hinge.angle.degrees))
        guard hinge.status == .partiallyOpen else { return }
        settle = Task { @MainActor in
            try? await Task.sleep(for: hingeSettleDelay)
            if !Task.isCancelled { animate(to: 0) }
        }
    }

    private func animate(to value: Double) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { hingeClosing = value }
    }
}

#else

private struct HingeRecedeModifier: ViewModifier {
    func body(content: Content) -> some View { content }
}

#endif
