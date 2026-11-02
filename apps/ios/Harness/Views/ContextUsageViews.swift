// The context ring and its card (desktop: crates/ui/src/context_usage.rs, context_window.rs).
//
// The ring sits at the far end of the status strip (beside the agent work chip) and on the Duo's pill row:
// how full the context is, in the theme's muted text, amber from 75%, red from 90%. Tapping it opens the
// card: "Context" with the count of the window, the segment bar and its legend (ContextWindow.breakdown),
// the status line, used and remaining tokens, and what graff kept out of the context, with its meter.

import SwiftUI

/// The ring and percent; nothing while the agent reports no window.
struct ContextRing: View {
    let store: SessionStore
    /// On the Duo's glass pill row: its own glass capsule, the pill's height.
    var glass = false
    @State private var showCard = Self.demoCardOpen

    /// Rig (DEBUG): `-demo-context-card` opens the card on launch, for screenshots without a tap.
    #if DEBUG
    private static let demoCardOpen = ProcessInfo.processInfo.arguments.contains("-demo-context-card")
    #else
    private static let demoCardOpen = false
    #endif

    var body: some View {
        if let usage = store.contextUsage, usage.hasWindow {
            let fraction = usage.fraction
            let color = ContextRing.color(fraction)
            Button {
                showCard = true
            } label: {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(Theme.textFaint.opacity(0.25), lineWidth: 1.8)
                        Circle().trim(from: 0, to: min(max(fraction ?? 0, 0), 1))
                            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                    .padding(2)
                    Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(Theme.sans(12))
                        .monospacedDigit()
                }
                .foregroundStyle(color)
                .padding(.horizontal, glass ? 12 : 6)
                .frame(height: glass ? 36 : 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(RingSurface(glass: glass))
            // Above the chip, the arrow pointing down at it. Left free, the system put a card that
            // didn't fit above beside the chip, squeezed into the width left of it.
            .popover(isPresented: $showCard, arrowEdge: .bottom) {
                ContextCard(store: store, available: PopoverFit.availableWidth())
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(fraction.map { "Context \(Int(($0 * 100).rounded())) percent full" } ?? "Context")
            .accessibilityIdentifier("context-ring")
        }
    }

    static func color(_ fraction: Double?) -> Color {
        guard let fraction else { return Theme.textFaint }
        if fraction >= 0.9 { return Theme.danger }
        if fraction >= 0.75 { return Theme.warning }
        return Theme.textMuted
    }
}

private struct RingSurface: ViewModifier {
    let glass: Bool

    func body(content: Content) -> some View {
        if glass { content.glassEffect(.regular.interactive(), in: Capsule()) } else { content }
    }
}

extension ContextWindow.Slot {
    func color(_ history: ContextWindow.History) -> Color {
        guard let hex = hex(history) else { return Theme.textFaint }
        return Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
                     blue: Double(hex & 0xff) / 255)
    }
}

extension ContextWindow.SavedPart {
    /// Calm tones: neutral for what is in context, the legend's own colors for files and compaction (the
    /// summary blue even when sealed: the sealed slate sits too close to the neutral).
    var color: Color {
        switch self {
        case .inContext: Theme.textMuted.opacity(0.75)
        case .files: ContextWindow.Slot.files.color(.chat)
        case .compaction: ContextWindow.Slot.history.color(.summary)
        }
    }
}

/// How wide a popover may be: the window's safe width less a margin each side. The system clamps a wider
/// popover to the screen and centers its content, cutting both edges off: the context card (398pt) lost its
/// first and last letters on iPhone Duo's cover display, where the vertical bar leaves 382pt.
enum PopoverFit {
    static let margin: CGFloat = 16

    static func availableWidth(windowWidth: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat) -> CGFloat {
        max(0, windowWidth - leadingInset - trailingInset - 2 * margin)
    }

    /// For the key window of the foreground scene; nil without one (the card keeps its own width).
    @MainActor
    static func availableWidth() -> CGFloat? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return nil }
        return availableWidth(windowWidth: window.bounds.width, leadingInset: window.safeAreaInsets.left,
                              trailingInset: window.safeAreaInsets.right)
    }
}

/// The context card's width, bar segments and legend columns for the room it has.
struct ContextCardLayout: Equatable {
    static let idealSegmentWidth: CGFloat = 4
    static let minimumSegmentWidth: CGFloat = 2
    static let gap: CGFloat = 2
    static let padding: CGFloat = 14
    /// Below this card width the legend's two columns cut their labels, so it takes one.
    static let twoColumnMinimum: CGFloat = 320

    /// The card's width, padding included.
    var width: CGFloat
    var segmentWidth: CGFloat
    var legendColumns: Int

    static var idealWidth: CGFloat { barWidth(segmentWidth: idealSegmentWidth) + 2 * padding }

    static func barWidth(segmentWidth: CGFloat) -> CGFloat {
        CGFloat(ContextWindow.segments) * (segmentWidth + gap) - gap
    }

    /// The ideal 398pt card where it fits; narrower, the segments thin (the count stays) and the legend reflows
    /// into one column. Never narrower than the thinnest segments allow.
    static func fitting(_ available: CGFloat?) -> ContextCardLayout {
        let floor = barWidth(segmentWidth: minimumSegmentWidth) + 2 * padding
        let width = max(floor, min(idealWidth, available ?? idealWidth))
        let segments = CGFloat(ContextWindow.segments)
        let segment = min(idealSegmentWidth, (width - 2 * padding - (segments - 1) * gap) / segments)
        return ContextCardLayout(width: width, segmentWidth: segment,
                                 legendColumns: width >= twoColumnMinimum ? 2 : 1)
    }
}

/// The card: the window's breakdown, the counts, and graff's savings.
struct ContextCard: View {
    let store: SessionStore
    /// The width the popover may take (PopoverFit); nil keeps the ideal width.
    var available: CGFloat? = nil
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: ContextCardLayout { .fitting(available) }
    private static let gap = ContextCardLayout.gap

    var body: some View {
        let usage = store.contextUsage
        VStack(alignment: .leading, spacing: 10) {
            if let breakdown = ContextWindow.breakdown(usage: usage, transcript: store.entries) {
                header(breakdown)
                bar(breakdown)
                legend(breakdown)
                Text(ContextWindow.statusLine(breakdown))
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textFaint)
            } else {
                Text("Context window").font(Theme.sans(14, weight: .medium)).foregroundStyle(Theme.text)
            }
            Text(ContextWindow.details(usage))
                .font(Theme.sans(12))
                .foregroundStyle(Theme.textMuted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let savings = usage?.savings, savings.keptOutTokens > 0 {
                savingsMeter(savings, inContext: usage?.tokens ?? 0,
                             history: ContextWindow.breakdown(usage: usage, transcript: store.entries)?.history ?? .chat)
            }
        }
        .padding(ContextCardLayout.padding)
        .frame(width: layout.width)
        .background(Theme.surfaceDialog)
        .onAppear {
            // The bar fills left to right on open, then holds; reduced motion shows it full at once.
            if reduceMotion { filled = true } else { withAnimation(Motion.resize) { filled = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("context-card")
    }

    private func header(_ b: ContextWindow.Breakdown) -> some View {
        HStack {
            HStack(spacing: 4) {
                Text("Context").font(Theme.sans(14, weight: .medium)).foregroundStyle(Theme.text)
                Text(b.compacting ? "compacting" : "reading").font(Theme.sans(14)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            HStack(spacing: 3) {
                Text(ContextWindow.compactCount(b.tokens)).foregroundStyle(Theme.text)
                Text("of \(ContextWindow.compactCount(b.window))").foregroundStyle(Theme.textFaint)
            }
            .font(Theme.sans(14))
            .monospacedDigit()
        }
    }

    private func bar(_ b: ContextWindow.Breakdown) -> some View {
        let counts = ContextWindow.segmentCounts(b)
        var colors: [Color] = counts.flatMap { slot, count in Array(repeating: slot.color(b.history), count: count) }
        let lit = filled ? colors.count : 0
        colors += Array(repeating: Theme.textFaint.opacity(0.22), count: max(0, ContextWindow.segments - colors.count))
        return HStack(spacing: Self.gap) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < lit ? colors[index] : Theme.textFaint.opacity(0.22))
                    .frame(width: layout.segmentWidth, height: 16)
            }
        }
        .accessibilityHidden(true)
    }

    private func legend(_ b: ContextWindow.Breakdown) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading),
                            count: layout.legendColumns)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(b.items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).fill(item.0.color(b.history)).frame(width: 8, height: 8)
                    Text(item.0.label(b.history)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ContextWindow.compactCount(item.1)).foregroundStyle(Theme.textFaint).monospacedDigit()
                }
                .font(Theme.sans(12))
            }
        }
    }

    private func savingsMeter(_ savings: ContextSavings, inContext: Int, history: ContextWindow.History) -> some View {
        let parts = ContextWindow.savedSegments([(.inContext, inContext), (.files, savings.handleTokens),
                                                 (.compaction, savings.compactedTokens)])
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ContextWindow.compactCount(savings.keptOutTokens))
                    .font(Theme.sans(14, weight: .medium)).foregroundStyle(Theme.text)
                Text("saved by graff").font(Theme.sans(12)).foregroundStyle(Theme.textMuted)
            }
            .monospacedDigit()
            HStack(spacing: Self.gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    ForEach(0..<part.count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(filled ? part.part.color : Theme.textFaint.opacity(0.22))
                            .frame(width: layout.segmentWidth, height: 8)
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5).fill(part.part.color).frame(width: 6, height: 6)
                        Text(part.part.label)
                    }
                }
            }
            .font(Theme.sans(11))
            .foregroundStyle(Theme.textFaint)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}
