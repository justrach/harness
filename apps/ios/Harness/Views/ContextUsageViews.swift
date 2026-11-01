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
            .popover(isPresented: $showCard) {
                ContextCard(store: store).presentationCompactAdaptation(.popover)
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

/// The card: the window's breakdown, the counts, and graff's savings.
struct ContextCard: View {
    let store: SessionStore
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let segmentWidth: CGFloat = 4
    private static let gap: CGFloat = 2
    private static var barWidth: CGFloat {
        CGFloat(ContextWindow.segments) * (segmentWidth + gap) - gap
    }

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
        .padding(14)
        .frame(width: Self.barWidth + 28)
        .background(Theme.surfaceDialog)
        .onAppear {
            // The bar fills left to right on open, then holds; reduced motion shows it full at once.
            if reduceMotion { filled = true } else { withAnimation(Motion.resize) { filled = true } }
        }
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
                    .frame(width: Self.segmentWidth, height: 16)
            }
        }
        .accessibilityHidden(true)
    }

    private func legend(_ b: ContextWindow.Breakdown) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12, alignment: .leading),
                       GridItem(.flexible(), spacing: 12, alignment: .leading)]
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
                            .frame(width: Self.segmentWidth, height: 8)
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
