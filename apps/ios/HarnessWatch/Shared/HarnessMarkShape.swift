// The Harness mark: the ring, `</>` and the trailing pixels. Shared by the
// iPhone app (HarnessMark in SignInView), the Watch app and its complication.

import SwiftUI

struct HarnessMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var ring = Path()
        ring.move(to: CGPoint(x: 778, y: 275))
        ring.addCurve(to: CGPoint(x: 418, y: 205), control1: CGPoint(x: 678, y: 180), control2: CGPoint(x: 545, y: 160))
        ring.addCurve(to: CGPoint(x: 222, y: 526), control1: CGPoint(x: 272, y: 255), control2: CGPoint(x: 212, y: 389))
        ring.addCurve(to: CGPoint(x: 531, y: 814), control1: CGPoint(x: 234, y: 700), control2: CGPoint(x: 371, y: 812))
        ring.addCurve(to: CGPoint(x: 794, y: 722), control1: CGPoint(x: 650, y: 817), control2: CGPoint(x: 733, y: 772))
        path.addPath(ring.strokedPath(StrokeStyle(lineWidth: 108, lineCap: .round)))

        for points in [
            [CGPoint(x: 456, y: 457), CGPoint(x: 383, y: 500), CGPoint(x: 456, y: 543)],
            [CGPoint(x: 536, y: 437), CGPoint(x: 493, y: 563)],
            [CGPoint(x: 578, y: 457), CGPoint(x: 651, y: 500), CGPoint(x: 578, y: 543)],
        ] {
            var glyph = Path()
            glyph.addLines(points)
            path.addPath(glyph.strokedPath(StrokeStyle(lineWidth: 31, lineCap: .round, lineJoin: .round)))
        }

        let pixels: [(CGFloat, CGFloat, CGFloat)] = [
            (802, 455, 27), (849, 495, 38), (790, 552, 48),
            (860, 574, 23), (823, 630, 34), (893, 662, 18),
        ]
        for (x, y, size) in pixels {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: size, height: size),
                                cornerSize: CGSize(width: size / 7, height: size / 7))
        }

        let scale = min(rect.width, rect.height) / 1000
        let dx = rect.minX + (rect.width - 1000 * scale) / 2
        let dy = rect.minY + (rect.height - 1000 * scale) / 2
        return path.applying(CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}
