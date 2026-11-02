// The lifted session column, after the desktop's (crates/ui/src/shell.rs `content_plane`, `seam_fillet`).
//
// Where a session sits beside another column (the list on iPad and in iPhone Duo's book pose, Inspect on a
// Duo lying flat, the list in the phone split side by side), the session's page is lifted: light themes wash
// it toward white (`Theme.liftedPage`), so the other column's tone reads as chrome around a bright page. Where
// the two meet, the page's corners round and the hairline follows the curve, instead of a straight rule. The
// column stays flush: no inset card, no margins; only the two corners at the seam change.

import SwiftUI

extension EnvironmentValues {
    /// The session's page is lifted (`Theme.sessionPage(lifted:)`): it sits beside another column.
    @Entry var liftedPlane: Bool = false
}

extension View {
    /// Round this column's two corners on `edge`, where it meets the column beside it, whose tone (`chrome`)
    /// fills the corners; the hairline runs down the seam and around both curves. Draws over the column,
    /// full height (under the bars too), and takes no touches. Not `shown`: the straight edge.
    ///
    /// Only the vertical safe area is ignored: on iPad the split view's detail column reaches under the
    /// sidebar, with a leading safe area as wide as it, so the column's visible edge is that inset.
    func seam(_ edge: HorizontalEdge, chrome: Color, when shown: Bool = true) -> some View {
        overlay {
            if shown {
                ZStack {
                    SeamFillets(edge: edge).fill(chrome)
                    SeamLine(edge: edge).stroke(Theme.border, lineWidth: 1)
                }
                .ignoresSafeArea(edges: .vertical)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// The two corners outside the column's rounded edge: a square each, less the quarter circle.
private struct SeamFillets: Shape {
    let edge: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        let r = min(Theme.seamRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        // Drawn for a leading seam; a trailing one is the mirror image.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(180),
                    clockwise: true)
        path.closeSubpath()
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height - r))
        path.addArc(center: CGPoint(x: r, y: rect.height - r), radius: r, startAngle: .degrees(180),
                    endAngle: .degrees(90), clockwise: true)
        path.closeSubpath()
        return mirrored(path, edge: edge, in: rect)
    }
}

/// The seam's hairline: down the column's edge, around both rounded corners. Half a point in, so the whole
/// line stays inside the column.
private struct SeamLine: Shape {
    let edge: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        let r = min(Theme.seamRadius, rect.height / 2, rect.width / 2)
        let x = 0.5
        var path = Path()
        path.move(to: CGPoint(x: r + x, y: 0))
        path.addArc(center: CGPoint(x: r + x, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(180),
                    clockwise: true)
        path.addLine(to: CGPoint(x: x, y: rect.height - r))
        path.addArc(center: CGPoint(x: r + x, y: rect.height - r), radius: r, startAngle: .degrees(180),
                    endAngle: .degrees(90), clockwise: true)
        return mirrored(path, edge: edge, in: rect)
    }
}

private func mirrored(_ path: Path, edge: HorizontalEdge, in rect: CGRect) -> Path {
    let path = path.offsetBy(dx: rect.minX, dy: rect.minY)
    guard edge == .trailing else { return path }
    return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * rect.minX + rect.width, ty: 0))
}
