// Harness's paint and layout tokens. Paint comes from the active desktop theme
// variant (ThemeStore, fed by the desktop's own registry in themes.json), so
// every surface and accent lands on the same sRGB values the desktop paints.
// **Numbers drive layout, colors are paint**: layout constants are plain
// numbers and never depend on which color is painted.

import SwiftUI

enum Theme {
    private static var palette: ThemePalette { ThemeStore.shared.palette }

    // ---- paint: surfaces ----
    /// Main panel background.
    static var bg: Color { palette.bg }
    /// Shell / sidebar surface.
    static var surface: Color { palette.surface }
    /// Raised surface: popovers, dialogs, cards.
    static var surfaceRaised: Color { palette.surfaceRaised }
    /// Sheet and dialog panel.
    static var surfaceDialog: Color { palette.surfaceDialog }
    /// Hover/pressed wash for interactive rows.
    static var elementHover: Color { palette.elementHover }
    /// Active/selected wash.
    static var elementActive: Color { palette.elementActive }
    /// Hairline border.
    static var border: Color { palette.border }
    /// Stronger border for focused/raised edges.
    static var borderStrong: Color { palette.borderStrong }

    // ---- paint: text ----
    static var text: Color { palette.text }
    static var textMuted: Color { palette.textMuted }
    static var textFaint: Color { palette.textFaint }

    // ---- paint: accents ----
    static var accent: Color { palette.accent }
    static var accentStrong: Color { palette.accentStrong }
    static var danger: Color { palette.danger }
    static var dangerSoft: Color { palette.dangerSoft }
    static var warning: Color { palette.warning }

    // ---- paint: status dots (shell/spaces.rs status_dot_color) ----
    static var statusWorking: Color { palette.statusWorking }
    static var statusCompleted: Color { palette.statusCompleted }
    /// Claude brand orange — the same in every theme.
    static let claudeBrand = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

    // ---- paint: markdown inline code ----
    static var inlineCodeText: Color { palette.inlineCodeText }
    static var inlineCodeWash: Color { palette.inlineCodeWash }

    // ---- paint: syntax tokens ----
    static var tokenKeyword: Color { palette.tokenKeyword }
    static var tokenString: Color { palette.tokenString }
    static var tokenNumber: Color { palette.tokenNumber }

    // ---- numbers drive layout (pt) ----
    static let bubbleRadius: CGFloat = 22
    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let spaceXS: CGFloat = 4
    static let spaceSM: CGFloat = 8
    static let spaceMD: CGFloat = 12
    static let spaceLG: CGFloat = 16
}

// MARK: - Fonts

extension Theme {
    static let fontSansName = "Geist"
    static let fontMonoName = "GeistMono-Regular"

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Static weight cuts register as separate families — select by
        // PostScript name so weights actually resolve.
        let name: String
        if weight == .medium {
            name = "Geist-Medium"
        } else if weight == .semibold {
            name = "Geist-SemiBold"
        } else if weight == .bold {
            name = "Geist-Bold"
        } else {
            name = "Geist-Regular"
        }
        return .custom(name, size: size)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(fontMonoName, size: size).weight(weight)
    }

    static func sansUI(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight]
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Geist",
            .traits: traits,
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func monoUI(_ size: CGFloat) -> UIFont {
        UIFont(name: fontMonoName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Translucent ink (ported from crates/ui/src/theme.rs)
//
// Alphas are quoted in dark-mode terms at every call site — the dark theme is
// the tuned one — and the light value is derived, exactly as on the desktop.

/// Translucent **fill** ink for washes, chips and pressed states: white on
/// dark themes, black on light ones.
func ink(_ alpha: Double) -> Color {
    ThemeStore.shared.palette.isDark
        ? Color.white.opacity(alpha)
        : Color.black.opacity(alpha * inkFillScale)
}

/// Translucent **hairline** ink for borders, dividers and rings. Separate from
/// `ink` because a 1pt line needs *more* ink on a bright field, a plate less.
func hairline(_ alpha: Double) -> Color {
    ThemeStore.shared.palette.isDark
        ? Color.white.opacity(alpha)
        : Color.black.opacity(min(alpha * inkHairlineScale, 0.5))
}

private let inkFillScale = 1.0
private let inkHairlineScale = 1.35
