import SwiftUI
import UIKit

/// A single, in-memory transition preview of this view's own app window.
/// UIKit reflows the Duo's native vertical bar when a live navigation stack
/// moves off its window edge. A retained preview lets the whole page travel
/// without that relayout. Nothing is saved, logged or uploaded.
@MainActor @Observable
final class CoverPageSnapshot {
    @ObservationIgnored weak var window: UIWindow?
    private(set) var image: UIImage?

    @discardableResult
    func capture() -> Bool {
        guard let window, window.bounds.width > 0, window.bounds.height > 0 else { return false }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) {
                window.layer.render(in: context.cgContext)
            }
        }
        return true
    }

    func clear() { image = nil }
}

/// Resolve only the window containing this navigation page, never another scene.
struct CoverPageSnapshotSource: UIViewRepresentable {
    let snapshot: CoverPageSnapshot

    func makeUIView(context: Context) -> SourceView {
        let view = SourceView()
        view.snapshot = snapshot
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SourceView, context: Context) {
        view.snapshot = snapshot
        snapshot.window = view.window
    }

    final class SourceView: UIView {
        weak var snapshot: CoverPageSnapshot?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            snapshot?.window = window
        }
    }
}
