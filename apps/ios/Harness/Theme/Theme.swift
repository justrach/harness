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

// MARK: - Project tints

extension Theme {
    /// A project's own color, keyed by its space id: the same project reads
    /// the same on every device, with a deeper cut of each hue for light mode.
    static func projectTint(_ key: String) -> Color {
        projectTints[projectTintIndex(key)]
    }

    /// Which of the tints a project gets (the Live Activity draws its own copy).
    static func projectTintIndex(_ key: String) -> Int {
        Int(fnv1a(key) % UInt64(projectTints.count))
    }

    /// Coral, amber, green, teal, sky, indigo, violet, pink.
    private static let projectTints: [Color] = [25.0, 70, 145, 185, 235, 265, 300, 340].map { hue in
        adaptive(dark: oklch(0.76, 0.13, hue), light: oklch(0.52, 0.16, hue))
    }
}

/// FNV-1a: a hash that is stable across launches (Swift's `Hasher` is seeded).
func fnv1a(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}

// MARK: - Color primitives (ported from theme.rs)

/// One token, two paints: resolves per trait collection, so SwiftUI and
/// UIKit (`UIColor(Theme.x)`) both follow appearance changes live.
func adaptive(dark: Color, light: Color) -> Color {
    let dark = UIColor(dark), light = UIColor(light)
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .light ? light : dark })
}

/// oklch (CSS notation: L 0..1, C, H degrees) → sRGB Color.
func oklch(_ l: Double, _ c: Double, _ hDeg: Double) -> Color {
    let rgb = oklchToSrgb(l: l, c: c, hDeg: hDeg)
    return Color(red: Double(rgb[0]), green: Double(rgb[1]), blue: Double(rgb[2]))
}

/// oklch → sRGB (each 0..1, clamped/gamut-clipped per channel).
func oklchToSrgb(l: Double, c: Double, hDeg: Double) -> [Double] {
    let h = hDeg * .pi / 180
    let a = c * cos(h)
    let b = c * sin(h)

    // OKLab → LMS (cube roots undone)
    let l_ = l + 0.39633778 * a + 0.21580376 * b
    let m_ = l - 0.105561346 * a - 0.06385417 * b
    let s_ = l - 0.08948418 * a - 1.2914855 * b
    let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)

    // LMS → linear sRGB
    let r = 4.0767417 * l3 - 3.3077116 * m3 + 0.23096993 * s3
    let g = -1.268438 * l3 + 2.6097574 * m3 - 0.3413194 * s3
    let bl = -0.0041960863 * l3 - 0.7034186 * m3 + 1.7076147 * s3

    return [gammaEncode(r), gammaEncode(g), gammaEncode(bl)]
}

private func gammaEncode(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
}

// MARK: - Appearance

extension View {
    /// Apply the chosen appearance mode. Pinned Light/Dark force the scheme so
    /// system chrome (keyboard, glass, menus) matches the palette; System
    /// leaves it to the device. Sheets get it too so a presentation never
    /// disagrees with the screen under it.
    func harnessAppearance() -> some View {
        preferredColorScheme(ThemeStore.shared.preferredScheme)
    }

    /// Grouped lists (Settings, Profile and their pages) on the theme's own
    /// panel instead of the system's grouped gray, which read as the app
    /// changing theme whenever Settings opened. Pair with
    /// [`harnessListRow`] on each section for the card surface.
    func harnessGroupedList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
    }

    /// A grouped list section's rows on the theme's raised card surface.
    func harnessListRow() -> some View {
        listRowBackground(Theme.surfaceRaised)
    }
}
