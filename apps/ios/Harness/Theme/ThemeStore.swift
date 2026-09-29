// The active theme: a light and a dark variant from the desktop catalog plus
// an appearance mode, mirroring the desktop's `ThemeSelection`.
//
// By default the phone matches the desktop: the desktop publishes its choice
// to the synced registry (`preferences/appearance`) and `applyDesktop` feeds
// it in here. Choosing a mode or theme on the phone stops matching and keeps
// the phone's own choice; turning "Match desktop" back on re-adopts the
// desktop's.
//
// `Theme`'s paint tokens read `ThemeStore.shared.palette`. The store is
// @Observable, so any view body that paints a token re-renders when the
// palette changes — call sites never mention the store.
//
// The phone's own choice persists in UserDefaults, which also reads launch
// arguments: `-theme.mode dark -theme.dark nord` pins a theme for screenshots.

import SwiftUI
import UIKit

/// The desktop's appearance choice as published to the registry.
struct DesktopAppearance: Equatable {
    let mode: String
    let light: String
    let dark: String
}

@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// New installs match a new desktop install (`ThemeSelection::default`,
    /// appearance System): Codegraff, following the device.
    static let defaultLight = "codegraff-light"
    static let defaultDark = "codegraff-dark"
    /// The desktop's resolve fallback for an unknown or mismatched id.
    static let fallbackLight = "harnesser-light"
    static let fallbackDark = "harnesser-dark"

    let catalog: ThemeCatalog

    /// The phone's own choice, used whenever it isn't matching the desktop.
    private(set) var ownMode: Mode
    private(set) var ownLight: String
    private(set) var ownDark: String
    /// "Match desktop" — on by default; the first local choice turns it off.
    private(set) var followDesktop: Bool
    /// The desktop's latest published choice (nil until one has synced).
    private(set) var desktop: DesktopAppearance?
    private(set) var active: ThemeVariant
    private(set) var palette: ThemePalette

    /// The device appearance, tracked from the scene's screen so it stays
    /// correct while the app forces its own style.
    @ObservationIgnored private var systemAppearance: ThemeAppearance = .dark
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var traitRegistration: (any UITraitChangeRegistration)?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let mode = "theme.mode"
        static let light = "theme.light"
        static let dark = "theme.dark"
        static let followDesktop = "theme.followDesktop"
    }

    init(catalog: ThemeCatalog = .builtin, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.defaults = defaults
        ownMode = defaults.string(forKey: Keys.mode).flatMap(Mode.init) ?? .system
        let ownDark = defaults.string(forKey: Keys.dark) ?? Self.defaultDark
        ownLight = defaults.string(forKey: Keys.light) ?? Self.defaultLight
        self.ownDark = ownDark
        followDesktop = defaults.object(forKey: Keys.followDesktop) as? Bool ?? true
        let variant = Self.variant(in: catalog, id: ownDark, appearance: .dark)
        active = variant
        palette = ThemePalette(variant)
        resolve()
    }

    // MARK: Effective choice

    /// True while the phone is showing the desktop's choice.
    var isMatchingDesktop: Bool { followDesktop && desktopMode != nil }

    /// The mode in effect — the desktop's while matching, else the phone's.
    var mode: Mode { isMatchingDesktop ? desktopMode! : ownMode }

    func selectedId(for appearance: ThemeAppearance) -> String {
        if isMatchingDesktop, let desktop {
            return appearance == .dark ? desktop.dark : desktop.light
        }
        return appearance == .dark ? ownDark : ownLight
    }

    /// The active palette's color scheme (for environment values).
    var colorScheme: ColorScheme { active.appearance.colorScheme }

    /// What to pass to `preferredColorScheme`: nothing while following the
    /// system, so the device keeps driving the window and its sheets.
    var preferredScheme: ColorScheme? { mode == .system ? nil : colorScheme }

    private var desktopMode: Mode? { desktop.flatMap { Mode(rawValue: $0.mode) } }

    // MARK: Changes

    /// The registry's latest desktop choice (WorkspaceStore calls this on
    /// every projection; nil while signed out or before the desktop publishes).
    func applyDesktop(_ appearance: DesktopAppearance?) {
        guard appearance != desktop else { return }
        desktop = appearance
        resolve()
    }

    func setFollowDesktop(_ follow: Bool) {
        guard follow != followDesktop else { return }
        if !follow { adoptEffectiveChoice() }
        followDesktop = follow
        defaults.set(follow, forKey: Keys.followDesktop)
        resolve()
    }

    /// Choose a mode on the phone (stops matching the desktop).
    func setMode(_ mode: Mode) {
        detachFromDesktop()
        guard mode != ownMode else { return }
        ownMode = mode
        persist(mode.rawValue, Keys.mode)
        resolve()
    }

    /// Choose `variant` for its appearance (stops matching the desktop).
    /// Picking a light theme while the app is pinned dark (or vice versa)
    /// switches the pin so the choice shows.
    func select(_ variant: ThemeVariant) {
        detachFromDesktop()
        switch variant.appearance {
        case .light:
            ownLight = variant.id
            persist(variant.id, Keys.light)
        case .dark:
            ownDark = variant.id
            persist(variant.id, Keys.dark)
        }
        if ownMode != .system, ownMode.rawValue != variant.appearance.rawValue {
            ownMode = variant.appearance == .dark ? .dark : .light
            persist(ownMode.rawValue, Keys.mode)
        }
        resolve()
    }

    /// A local choice starts from what's on screen, so changing one thing
    /// never makes the others jump back to stale phone-only values.
    private func detachFromDesktop() {
        guard isMatchingDesktop else { return }
        setFollowDesktop(false)
    }

    private func adoptEffectiveChoice() {
        guard isMatchingDesktop else { return }
        let (mode, light, dark) = (self.mode, selectedId(for: .light), selectedId(for: .dark))
        ownMode = mode
        ownLight = light
        ownDark = dark
        persist(mode.rawValue, Keys.mode)
        persist(light, Keys.light)
        persist(dark, Keys.dark)
    }

    /// Follow the device appearance of `scene` (needed for `.system`).
    ///
    /// The device style is read from the scene's *screen*: a pinned
    /// `preferredColorScheme` overrides the scene's own traits, so they echo
    /// the app's choice back. `.system` applies no override
    /// (`preferredScheme` is nil), which keeps these change callbacks live.
    @MainActor
    func attach(to scene: UIWindowScene) {
        self.scene = scene
        traitRegistration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (scene: UIWindowScene, _: UITraitCollection) in
            // The scene's new traits are current here; its screen's may lag.
            // While a mode is pinned this echoes the pin, which `.system`
            // ignores until the pin lifts and the device value arrives.
            self?.systemAppearance = Self.appearance(of: scene.traitCollection)
            self?.resolve()
        }
        refreshSystemAppearance()
    }

    /// Re-read the device appearance — also called when the app becomes
    /// active, since a style flipped from Control Center can land while the
    /// scene's own traits are pinned by the override.
    @MainActor
    func refreshSystemAppearance() {
        guard let scene else { return }
        systemAppearance = Self.appearance(of: scene.screen.traitCollection)
        resolve()
    }

    private func resolve() {
        let appearance: ThemeAppearance = switch mode {
        case .system: systemAppearance
        case .light: .light
        case .dark: .dark
        }
        let variant = Self.variant(in: catalog, id: selectedId(for: appearance), appearance: appearance)
        guard variant != active else { return }
        active = variant
        palette = ThemePalette(variant)
    }

    private func persist(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func appearance(of traits: UITraitCollection) -> ThemeAppearance {
        traits.userInterfaceStyle == .light ? .light : .dark
    }

    /// The desktop's fallback rule: an unknown id, or one of the wrong
    /// appearance, resolves to the Harness variant for that appearance.
    private static func variant(in catalog: ThemeCatalog, id: String, appearance: ThemeAppearance) -> ThemeVariant {
        if let variant = catalog.variant(id), variant.appearance == appearance { return variant }
        let fallback = appearance == .dark ? fallbackDark : fallbackLight
        guard let variant = catalog.variant(fallback) else {
            preconditionFailure("the catalog always contains both Harness variants")
        }
        return variant
    }
}

/// The roles the phone paints, resolved from one variant exactly the way the
/// desktop's `Theme::from_variant` (crates/ui/src/theme.rs) resolves them.
struct ThemePalette {
    let isDark: Bool
    let bg, surface, surfaceRaised, surfaceDialog, elementHover, elementActive: Color
    let border, borderStrong, text, textMuted, textFaint: Color
    let accent, accentStrong, danger, dangerSoft, warning: Color
    let statusWorking, statusCompleted, inlineCodeText, inlineCodeWash: Color
    let tokenKeyword, tokenString, tokenNumber: Color

    init(_ variant: ThemeVariant) {
        let colors = variant.colors
        let accent = variant.accent
        isDark = variant.appearance == .dark
        bg = colors.background.color
        surface = colors.shell.color
        surfaceRaised = colors.raised.color
        surfaceDialog = colors.dialog.color
        elementHover = colors.hover.color
        elementActive = colors.active.color
        border = colors.border.color
        borderStrong = colors.borderStrong.color
        text = colors.text.color
        textMuted = colors.textMuted.color
        textFaint = colors.textFaint.color
        self.accent = accent.primary.color
        accentStrong = accent.strong.color
        danger = colors.danger.color
        dangerSoft = colors.dangerMuted.color
        warning = colors.warning.color
        statusWorking = accent.activity.color
        statusCompleted = colors.success.color
        inlineCodeText = accent.primary.color
        inlineCodeWash = accent.wash.color
        let syntax = { (key: String) in variant.syntax[key]?.color ?? accent.primary.color }
        tokenKeyword = syntax("keyword")
        tokenString = syntax("string")
        tokenNumber = syntax("number")
    }
}
