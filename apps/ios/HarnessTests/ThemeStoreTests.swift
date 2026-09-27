import XCTest
@testable import Harness

final class ThemeStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "ThemeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testBundledCatalogIsTheDesktopRegistry() {
        let catalog = ThemeCatalog.builtin
        XCTAssertEqual(catalog.families.count, 19)
        XCTAssertEqual(catalog.variants.count, 31)
        XCTAssertEqual(Set(catalog.variants.map(\.id)).count, 31, "variant ids are unique")
        XCTAssertNotNil(catalog.variant("codegraff-dark"))
        XCTAssertNotNil(catalog.variant("harnesser-light"))
    }

    func testHexColorsDecodeEveryCssLength() {
        XCTAssertEqual(HexColor("#fff")?.red, 1)
        XCTAssertEqual(HexColor("#0000")?.alpha, 0)
        XCTAssertEqual(HexColor("#16140f")?.alpha, 1)
        let wash = HexColor("#8b7cf638")
        XCTAssertEqual(wash?.red ?? 0, 0x8b / 255.0, accuracy: 1e-9)
        XCTAssertEqual(wash?.alpha ?? 0, 0x38 / 255.0, accuracy: 1e-9)
        XCTAssertNil(HexColor("8b7cf6"))
        XCTAssertNil(HexColor("#12345"))
    }

    func testNewInstallMatchesADesktopInstall() {
        let store = ThemeStore(defaults: freshDefaults())
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.selectedId(for: .dark), "codegraff-dark")
        XCTAssertEqual(store.selectedId(for: .light), "codegraff-light")
        XCTAssertNil(store.preferredScheme, "System mode leaves the scheme to the device")
    }

    func testPinnedModesResolveTheirVariantAndPersist() {
        let defaults = freshDefaults()
        let store = ThemeStore(defaults: defaults)
        store.setMode(.light)
        XCTAssertEqual(store.active.id, "codegraff-light")
        XCTAssertEqual(store.preferredScheme, .light)

        store.select(ThemeCatalog.builtin.variant("nord")!)
        XCTAssertEqual(store.mode, .dark, "picking a dark theme while pinned light shows it")
        XCTAssertEqual(store.active.id, "nord")

        let reopened = ThemeStore(defaults: defaults)
        XCTAssertEqual(reopened.mode, .dark)
        XCTAssertEqual(reopened.active.id, "nord")
        XCTAssertEqual(reopened.selectedId(for: .light), "codegraff-light")
    }

    /// A `preferences/appearance` row as the edge broadcasts it after the
    /// desktop's `setAppearance` (crates/doc/src/registry/appearance.rs).
    private func desktopRow(seq: UInt64, mode: String, light: String, dark: String, ms: Int64) throws -> RegistryRow {
        let clock = encodeHlc(ms: ms, counter: 0, device: "desktop")
        let json = """
        {"kind":"preferences","id":"appearance","seq":\(seq),"deleted":false,
         "fields":{"mode":"\(mode)","light":"\(light)","dark":"\(dark)"},
         "clocks":{"mode":"\(clock)","light":"\(clock)","dark":"\(clock)"}}
        """
        return try JSONDecoder().decode(RegistryRow.self, from: Data(json.utf8))
    }

    func testPhoneFollowsTheDesktopThroughTheRegistry() throws {
        let doc = RegistryDoc(deviceId: "ios-test")
        let store = ThemeStore(defaults: freshDefaults())
        store.applyDesktop(doc.desktopAppearance)
        XCTAssertNil(store.desktop)
        XCTAssertEqual(store.active.id, "codegraff-dark", "no desktop yet: the phone's defaults")

        doc.applyState(seq: 1, full: true, gcFloor: 0,
                       rows: [try desktopRow(seq: 1, mode: "dark", light: "github-light", dark: "nord", ms: 1000)])
        store.applyDesktop(doc.desktopAppearance)
        XCTAssertTrue(store.isMatchingDesktop)
        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(store.active.id, "nord")

        // The desktop switches theme; the phone follows on the next rows frame.
        _ = doc.applyRows(seq: 2, rows: [try desktopRow(seq: 2, mode: "light", light: "github-light", dark: "nord", ms: 2000)])
        store.applyDesktop(doc.desktopAppearance)
        XCTAssertEqual(store.active.id, "github-light")
        XCTAssertEqual(store.preferredScheme, .light)
    }

    func testALocalChoiceStopsMatchingUntilMatchingIsTurnedBackOn() {
        let defaults = freshDefaults()
        let store = ThemeStore(defaults: defaults)
        store.applyDesktop(DesktopAppearance(mode: "dark", light: "github-light", dark: "nord"))
        XCTAssertEqual(store.active.id, "nord")

        store.select(ThemeCatalog.builtin.variant("dracula")!)
        XCTAssertFalse(store.followDesktop)
        XCTAssertEqual(store.active.id, "dracula")
        XCTAssertEqual(store.selectedId(for: .light), "github-light",
                       "detaching keeps the desktop's other choices instead of jumping")

        store.applyDesktop(DesktopAppearance(mode: "dark", light: "github-light", dark: "tokyo-night"))
        XCTAssertEqual(store.active.id, "dracula", "the phone's own choice sticks")
        XCTAssertFalse(ThemeStore(defaults: defaults).followDesktop, "and survives a relaunch")

        store.setFollowDesktop(true)
        XCTAssertEqual(store.active.id, "tokyo-night")
    }

    func testADesktopOnlyThemeFallsBackLikeTheDesktop() {
        let store = ThemeStore(defaults: freshDefaults())
        // An imported VS Code theme exists only on that desktop.
        store.applyDesktop(DesktopAppearance(mode: "dark", light: "codegraff-light", dark: "my-imported-theme"))
        XCTAssertEqual(store.active.id, "harnesser-dark")
    }

    func testUnknownOrMismatchedIdsFallBackLikeTheDesktop() {
        let defaults = freshDefaults()
        defaults.set("dark", forKey: "theme.mode")
        defaults.set("not-a-theme", forKey: "theme.dark")
        XCTAssertEqual(ThemeStore(defaults: defaults).active.id, "harnesser-dark")

        defaults.set("github-light", forKey: "theme.dark")
        XCTAssertEqual(ThemeStore(defaults: defaults).active.id, "harnesser-dark",
                       "a light variant can't fill the dark slot")
    }
}
