// Harness's look on the Watch: the Codegraff Dark palette from
// Harness/Theme/themes.json (`codegraff-dark`), Geist, and the Harness mark.
// The Watch has no theme picker, so the colours are fixed here.

import SwiftUI
import WatchKit

enum WatchTheme {
    static let bg = Color(hex: 0x16140F)
    static let card = Color(hex: 0x1F1C16)
    static let raised = Color(hex: 0x2A261E)
    static let border = Color.white.opacity(0.10)
    static let borderStrong = Color.white.opacity(0.18)
    static let text = Color(hex: 0xEDEAE2)
    static let muted = Color(hex: 0x9A9384)
    static let faint = Color(hex: 0x5C564B)
    static let accent = Color(hex: 0xE8A33D)
    static let accentLight = Color(hex: 0xEEBD73)
    static let accentWash = Color(hex: 0xE8A33D).opacity(0.22)
    static let onAccent = Color.black
    static let success = Color(hex: 0x7FA86B)
    static let danger = Color(hex: 0xD2674F)
    static let warning = Color(hex: 0xD9A441)

    static let cardRadius: CGFloat = 18

    /// Geist by weight (each cut registers as its own family).
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .medium: "Geist-Medium"
        case .semibold, .bold: "Geist-SemiBold"
        default: "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    static func mono(_ size: CGFloat) -> Font {
        .custom("GeistMono-Regular", size: size, relativeTo: .title3)
    }

    /// Small caps-style section label ("SEND TO", "EARLIER").
    static func eyebrow() -> Font { sans(11, .semibold, relativeTo: .caption2) }

    static func color(_ status: WatchLink.Status) -> Color {
        switch status {
        case .working: accent
        case .needsInput: warning
        case .failed: danger
        case .idle: faint
        }
    }

    static func haptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A raised card in the palette: fill, hairline and the Watch's radius.
struct CardBackground: ViewModifier {
    var fill: Color = WatchTheme.card
    var stroke: Color = WatchTheme.border

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WatchTheme.cardRadius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

extension View {
    func card(fill: Color = WatchTheme.card, stroke: Color = WatchTheme.border) -> some View {
        modifier(CardBackground(fill: fill, stroke: stroke))
    }
}

/// The status dot; a working chat's breathes.
struct StatusDot: View {
    let status: WatchLink.Status
    var size: CGFloat = 7
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(WatchTheme.color(status))
            .frame(width: size, height: size)
            .overlay {
                if status == .working {
                    Circle()
                        .stroke(WatchTheme.accent.opacity(breathe ? 0 : 0.6), lineWidth: 2)
                        .scaleEffect(breathe ? 2.4 : 1)
                }
            }
            .onAppear {
                guard status == .working else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { breathe = true }
            }
    }
}

struct StatusLabel: View {
    let status: WatchLink.Status

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(status.label)
                .font(WatchTheme.sans(12, .medium, relativeTo: .caption))
                .foregroundStyle(status == .idle ? WatchTheme.muted : WatchTheme.color(status))
        }
    }
}

/// The amber pill every primary action uses.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WatchTheme.sans(16, .semibold, relativeTo: .headline))
            .foregroundStyle(WatchTheme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(WatchTheme.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Secondary actions: a quiet card-coloured pill.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = WatchTheme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WatchTheme.sans(15, .medium, relativeTo: .body))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(WatchTheme.raised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
