import SwiftUI

/// The Duo's one-line composer has two flexible siblings: the editor and model
/// token. Budget them from the proposed width instead of letting their intrinsic
/// minima widen the shared transcript/composer column beyond its safe area.
struct ComposerInlineLayout: Layout {
    var editorIndex: Int
    var tokenIndex: Int?
    private let spacing: CGFloat = 12

    static func flexibleWidths(available: CGFloat, hasToken: Bool) -> (editor: CGFloat, token: CGFloat) {
        let available = max(0, available)
        guard hasToken else { return (available, 0) }
        // Keep the usual 140pt editor when there is room, but allow narrow
        // panes to share what remains without claiming impossible minima.
        let editorMinimum = min(140, available - min(44, available / 2))
        let token = min(220, max(0, available - editorMinimum))
        return (available - token, token)
    }

    private func widths(_ width: CGFloat, subviews: Subviews) -> [CGFloat] {
        var widths = subviews.indices.map { index in
            index == editorIndex || index == tokenIndex ? 0 : subviews[index].sizeThatFits(.unspecified).width
        }
        let fixed = widths.reduce(0, +)
        let flexible = Self.flexibleWidths(available: width - fixed - spacing * CGFloat(max(0, subviews.count - 1)),
                                          hasToken: tokenIndex != nil)
        if widths.indices.contains(editorIndex) { widths[editorIndex] = flexible.editor }
        if let tokenIndex, widths.indices.contains(tokenIndex) { widths[tokenIndex] = flexible.token }
        return widths
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 352)
        let widths = widths(width, subviews: subviews)
        let height = subviews.indices.map {
            subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(bounds.width, subviews: subviews)
        var x = bounds.minX
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                                 proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }
}
