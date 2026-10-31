// The reasoning step as a slider, after the desktop's model picker (crates/ui/src/pickers/model_preview.rs
// `preview_reasoning`): a thumb over an accent track with a dot per level the model offers, Faster on the
// left and Deeper on the right. Let go between two levels and the thumb settles on the nearest over 150 ms
// (reduced motion snaps). A two-level Off/High ladder is a switch and reads Off and On; a model with one
// level has nothing to adjust, and one with none never opens this.

import SwiftUI

enum ReasoningSlider {
    /// How long the thumb takes to settle on a level once let go.
    static let settle = 0.15

    /// A two-choice Off/High ladder is a switch, whatever the provider (pickers.rs `binary_reasoning_switch`).
    static func isBinary(_ levels: [String]) -> Bool {
        levels.count == 2 && levels.contains("none") && levels.contains("high")
    }

    /// The level's name on this model's ladder: Off for none, On for a switch's High.
    static func label(_ level: String, levels: [String]) -> String {
        if level == "high", isBinary(levels) { return "On" }
        if level == "none" { return "Off" }
        return HarnessCatalog.reasoningLabel(level)
    }

    static func title(_ levels: [String]) -> String { isBinary(levels) ? "Thinking" : "Reasoning" }

    /// The words under the track's two ends.
    static func ends(_ levels: [String]) -> (low: String, high: String) {
        isBinary(levels) ? ("Off", "On") : ("Faster", "Deeper")
    }

    /// One level or none: nothing to slide between.
    static func hasSlider(_ levels: [String]) -> Bool { levels.count > 1 }

    /// The level nearest a point on the track (0 at the left end, 1 at the right).
    static func nearestIndex(_ fraction: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int((min(max(fraction, 0), 1) * Double(count - 1)).rounded())
    }

    /// Where level `index` sits on the track.
    static func fraction(of index: Int, count: Int) -> Double {
        count > 1 ? Double(min(max(index, 0), count - 1)) / Double(count - 1) : 0
    }

    /// Where the thumb starts: on the chosen level, or the first when it isn't on this ladder.
    static func fraction(of level: String?, in levels: [String]) -> Double {
        fraction(of: level.flatMap { levels.firstIndex(of: $0) } ?? 0, count: levels.count)
    }
}

/// The track, its level dots and the thumb. `position` is where the thumb is drawn (0...1); `selection` follows
/// the nearest level live while dragging.
struct ReasoningTrack: View {
    let levels: [String]
    @Binding var selection: String?
    /// The level the thumb came to rest on: committed once per release, not on every level a drag passes.
    var onSettle: (String) -> Void = { _ in }
    @State private var position: Double = 0
    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let overhang: CGFloat = 14
    private static let trackHeight: CGFloat = 24
    private static let height: CGFloat = 34

    var body: some View {
        let count = levels.count
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumb: CGFloat = dragging ? 30 : 28
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                    .frame(width: width + Self.overhang * 2, height: Self.trackHeight)
                    .offset(x: -Self.overhang)
                Capsule().fill(Theme.accent)
                    .frame(width: CGFloat(position) * width + Self.overhang * 2, height: Self.trackHeight)
                    .offset(x: -Self.overhang)
                ForEach(0..<count, id: \.self) { index in
                    let at = ReasoningSlider.fraction(of: index, count: count)
                    Circle()
                        .fill(at <= position ? Theme.onAccent.opacity(0.55) : Theme.textMuted.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .offset(x: CGFloat(at) * width - 2)
                }
                Circle()
                    .fill(Color(red: 1, green: 0xFE / 255, blue: 0xFA / 255))
                    .overlay(Circle().strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: CGFloat(position) * width - thumb / 2)
            }
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        position = min(max(value.location.x / max(width, 1), 0), 1)
                        pick(ReasoningSlider.nearestIndex(position, count: count))
                    }
                    .onEnded { _ in
                        dragging = false
                        settle(on: ReasoningSlider.nearestIndex(position, count: count))
                    }
            )
        }
        .frame(height: Self.height)
        .padding(.horizontal, Self.overhang)
        .onAppear { position = ReasoningSlider.fraction(of: selection, in: levels) }
        .accessibilityElement()
        .accessibilityLabel(ReasoningSlider.title(levels))
        .accessibilityValue(selection.map { ReasoningSlider.label($0, levels: levels) } ?? "Model default")
        .accessibilityAdjustableAction { direction in
            let current = selection.flatMap { levels.firstIndex(of: $0) } ?? 0
            settle(on: direction == .increment ? current + 1 : current - 1)
        }
        .accessibilityIdentifier("reasoning-slider")
    }

    private func pick(_ index: Int) {
        let level = levels[min(max(index, 0), levels.count - 1)]
        guard level != selection else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        selection = level
    }

    /// Settle the thumb on level `index`, easing out over 150 ms; reduced motion snaps.
    private func settle(on index: Int) {
        let index = min(max(index, 0), levels.count - 1)
        pick(index)
        onSettle(levels[index])
        let target = ReasoningSlider.fraction(of: index, count: levels.count)
        if reduceMotion {
            position = target
        } else {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: ReasoningSlider.settle)) { position = target }
        }
    }
}
