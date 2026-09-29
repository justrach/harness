// The desktop's built-in theme registry, read from `themes.json`.
//
// `themes.json` is generated from crates/theme (`harness-theme-export`) and a
// Rust test fails when it drifts, so every family, variant id and resolved
// color here is byte-identical to what the desktop app installs. Only the
// roles the phone paints are decoded; the rest of each variant is ignored.

import SwiftUI

struct ThemeCatalog: Decodable {
    let families: [ThemeFamily]

    static let builtin: ThemeCatalog = {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ThemeCatalog.self, from: data)
        else { preconditionFailure("themes.json is missing or malformed") }
        return catalog
    }()

    var variants: [ThemeVariant] { families.flatMap(\.variants) }

    func variant(_ id: String) -> ThemeVariant? {
        variants.first { $0.id == id }
    }

    /// Families with at least one variant of `appearance`, in registry order.
    func families(for appearance: ThemeAppearance) -> [ThemeFamily] {
        families.filter { $0.variants.contains { $0.appearance == appearance } }
    }
}

struct ThemeFamily: Decodable, Identifiable {
    let id: String
    let name: String
    let variants: [ThemeVariant]
}

enum ThemeAppearance: String, Decodable {
    case light, dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

struct ThemeVariant: Decodable, Identifiable, Equatable {
    let id: String
    let familyId: String
    let name: String
    let appearance: ThemeAppearance
    let colors: Colors
    let accent: Accent
    let syntax: [String: HexColor]

    struct Colors: Decodable, Equatable {
        let background, shell, raised, card, dialog, hover, active: HexColor
        let border, borderStrong, text, textMuted, textFaint: HexColor
        let danger, dangerMuted, warning, success, input: HexColor
    }

    struct Accent: Decodable, Equatable {
        let primary, strong, wash, on, selection, activity: HexColor
    }
}

/// A CSS hex color (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`) — the encoding
/// the Rust `Color` serializes to.
struct HexColor: Decodable, Equatable {
    let red, green, blue, alpha: Double

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HexColor(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "expected a CSS hex color, got \(raw)"))
        }
        self = parsed
    }

    init?(_ css: String) {
        guard css.hasPrefix("#") else { return nil }
        var digits = Array(css.dropFirst())
        if digits.count == 3 || digits.count == 4 {
            digits = digits.flatMap { [$0, $0] }
        }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(String(digits), radix: 16)
        else { return nil }
        let bytes = digits.count == 8 ? value : value << 8 | 0xff
        red = Double(bytes >> 24 & 0xff) / 255
        green = Double(bytes >> 16 & 0xff) / 255
        blue = Double(bytes >> 8 & 0xff) / 255
        alpha = Double(bytes & 0xff) / 255
    }
}
