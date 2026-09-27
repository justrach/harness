// Monochrome theme, dark and light — a direct port of crates/ui/src/theme.rs
// (`Theme::dark` / `Theme::light`). Every paint token resolves per trait, so
// the app follows the system appearance or the account menu's override.
//
// Colors are computed from the same oklch definitions the desktop app uses
// (Björn Ottosson's OKLab matrices, the ones CSS Color 4 specifies), so every
// surface and accent lands on identical sRGB values. **Numbers drive layout,
// colors are paint**: layout constants are plain numbers and never depend on
// which color is painted.

import SwiftUI

enum Theme {
    // ---- paint: neutral surfaces (oklch chroma 0) ----
    /// Main panel background — sampled #060606.
    static let bg = adaptive(dark: grey(6), light: grey(0xff))
    /// Shell / sidebar surface — sampled #0d0d0d.
    static let surface = adaptive(dark: grey(13), light: neutral(0.968))
    /// Raised surface: popovers, dialogs, cards.
    static let surfaceRaised = adaptive(dark: neutral(0.235), light: neutral(0.940))
    /// Hover/pressed wash for interactive rows (ink, low alpha).
    static let elementHover = ink(0.06)
    /// Active/selected wash.
    static let elementActive = ink(0.10)
    /// Hairline border — ink at low alpha so it reads on any surface.
    static let border = adaptive(dark: Color.white.opacity(0.08), light: Color.black.opacity(0.10))
    /// Stronger border for focused/raised edges.
    static let borderStrong = adaptive(dark: Color.white.opacity(0.14), light: Color.black.opacity(0.17))

    // ---- paint: text ----
    static let text = adaptive(dark: neutral(0.922), light: neutral(0.25))           // ~neutral-200 / 850
    static let textMuted = adaptive(dark: neutral(0.708), light: neutral(0.439))     // ~neutral-400 / 600
    static let textFaint = adaptive(dark: neutral(0.556), light: neutral(0.535))     // ~neutral-500

    // ---- paint: accents ----
    static let accent = adaptive(dark: oklch(0.673, 0.182, 276.935),        // indigo-400
                                 light: oklch(0.511, 0.262, 276.966))      // indigo-600
    static let accentStrong = adaptive(dark: oklch(0.585, 0.233, 277.117),  // indigo-500
                                       light: oklch(0.457, 0.240, 277.023)) // indigo-700
    static let danger = adaptive(dark: oklch(0.704, 0.191, 22.216),         // red-400
                                 light: oklch(0.577, 0.245, 27.325))       // red-600
    static let dangerSoft = adaptive(dark: oklch(0.808, 0.114, 19.571),     // red-300
                                     light: oklch(0.505, 0.213, 27.518))   // red-700
    static let warning = adaptive(dark: oklch(0.828, 0.189, 84.429),        // amber-400
                                  light: oklch(0.555, 0.163, 48.998))      // amber-700

    // ---- paint: status dots (shell/spaces.rs status_dot_color) ----
    static let statusWorking = adaptive(dark: oklch(0.718, 0.202, 349.761),   // pink-400
                                        light: oklch(0.592, 0.249, 0.584))    // pink-600
    static let statusCompleted = adaptive(dark: oklch(0.765, 0.177, 163.223), // emerald-400
                                          light: oklch(0.596, 0.145, 163.225)) // emerald-600
    /// Claude brand orange — kept even on the mono surface.
    static let claudeBrand = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

    // ---- paint: markdown inline code (violet family) ----
    static let inlineCodeText = adaptive(dark: oklch(0.811, 0.111, 293.571),  // violet-300
                                         light: oklch(0.491, 0.270, 292.581)) // violet-700
    static let inlineCodeWash = adaptive(dark: oklch(0.702, 0.183, 293.541).opacity(0.12), // violet-400 @ 0.12
                                         light: oklch(0.606, 0.250, 292.717).opacity(0.10)) // violet-500 @ 0.10

    // ---- paint: syntax tokens (soft, paint-only) ----
    static let tokenKeyword = adaptive(dark: oklch(0.709, 0.129, 20.0), light: oklch(0.520, 0.150, 20.0))   // soft rose
    static let tokenString = adaptive(dark: oklch(0.770, 0.110, 168.0), light: oklch(0.520, 0.110, 168.0))  // soft green
    static let tokenNumber = adaptive(dark: oklch(0.780, 0.120, 80.0), light: oklch(0.550, 0.130, 65.0))   // soft amber

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

// MARK: - Project tints

extension Theme {
    /// A project's own color, keyed by its space id: the same project reads
    /// the same on every device, with a deeper cut of each hue for light mode.
    static func projectTint(_ key: String) -> Color {
        projectTints[Int(fnv1a(key) % UInt64(projectTints.count))]
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

/// A neutral (chroma 0) oklch tone. Chroma 0 means r == g == b exactly.
func neutral(_ lightness: Double) -> Color {
    let v = Double(oklchToSrgb(l: lightness, c: 0, hDeg: 0)[0])
    return Color(red: v, green: v, blue: v)
}

/// Ink at the given alpha — the hairline/wash primitive: white on the dark
/// theme, near-black on the light one (theme.rs `ink`).
func ink(_ alpha: Double) -> Color {
    adaptive(dark: Color.white.opacity(alpha),
             light: Color(red: 0.1, green: 0.1, blue: 0.1).opacity(alpha))
}

/// One token, two paints: resolves per trait collection, so SwiftUI and
/// UIKit (`UIColor(Theme.x)`) both follow appearance changes live.
func adaptive(dark: Color, light: Color) -> Color {
    let dark = UIColor(dark), light = UIColor(light)
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .light ? light : dark })
}

/// The account menu's Appearance pick; `system` follows iOS.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension View {
    /// Apply the Appearance pick. Sheets get it too so a presentation never
    /// disagrees with the screen under it.
    func harnessAppearance() -> some View { modifier(AppearanceModifier()) }
}

private struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreference.storageKey) private var raw = AppearancePreference.system.rawValue

    func body(content: Content) -> some View {
        content.preferredColorScheme(AppearancePreference(rawValue: raw)?.colorScheme)
    }
}

/// An exact achromatic tone from an 8-bit channel value (`grey(13)` ≡ #0d0d0d).
func grey(_ value: UInt8) -> Color {
    let v = Double(value) / 255.0
    return Color(red: v, green: v, blue: v)
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
