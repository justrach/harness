// Appearance settings (Settings → Appearance) — the desktop's theme model on
// the phone: an appearance mode plus independent light and dark variant
// choices from the same catalog.
// Every row previews its variant in that variant's own colors, so the list
// reads as a palette catalog rather than a column of names.

import SwiftUI

struct AppearanceView: View {
    private let store = ThemeStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                matchDesktop
                modePicker
                ThemePreviewCard(variant: store.active)
                variantSection(.dark, title: "Dark theme")
                variantSection(.light, title: "Light theme")
                Text("The same themes as Harness on your desktop.")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(SheetStyle.panel)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matchDesktop: some View {
        SheetCard {
            Toggle(isOn: Binding(get: { store.followDesktop },
                                 set: { on in withAnimation(.easeInOut(duration: 0.2)) { store.setFollowDesktop(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Match desktop")
                        .font(Theme.sans(15))
                        .foregroundStyle(Theme.text)
                    Text(matchDesktopDetail)
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .accessibilityIdentifier("appearance-match-desktop")
        }
    }

    private var matchDesktopDetail: String {
        guard store.followDesktop else { return "Using this phone's own choice." }
        guard let desktop = store.desktop else { return "Waiting for your desktop to share its theme." }
        let name = { (id: String) in store.catalog.variant(id)?.name ?? id }
        let mode = ThemeStore.Mode(rawValue: desktop.mode)?.label ?? desktop.mode
        return "\(mode) · \(name(desktop.light)) and \(name(desktop.dark))"
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetLabel("Appearance")
            Picker("Appearance", selection: Binding(get: { store.mode }, set: { store.setMode($0) })) {
                ForEach(ThemeStore.Mode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance-mode")
        }
    }

    private func variantSection(_ appearance: ThemeAppearance, title: String) -> some View {
        let variants = store.catalog.variants.filter { $0.appearance == appearance }
        return VStack(alignment: .leading, spacing: 8) {
            SheetLabel(title)
            SheetCard {
                ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
                    if index > 0 { SheetSeparator() }
                    SheetSelectRow(
                        title: variant.name,
                        subtitle: familyName(variant),
                        selected: store.selectedId(for: appearance) == variant.id,
                        leading: AnyView(ThemeSwatch(variant: variant))
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { store.select(variant) }
                    }
                    .accessibilityIdentifier("theme-\(variant.id)")
                }
            }
        }
    }

    /// Family names only where they add something ("Ayu" under "Ayu Mirage"
    /// is noise; "Rosé Pine" under "Moon" is not).
    private func familyName(_ variant: ThemeVariant) -> String? {
        guard let family = store.catalog.families.first(where: { $0.id == variant.familyId }),
              !variant.name.localizedCaseInsensitiveContains(family.name)
        else { return nil }
        return family.name
    }
}

/// A variant's palette at a glance: its background plate carrying text,
/// accent, string and warning marks.
struct ThemeSwatch: View {
    let variant: ThemeVariant

    var body: some View {
        let colors = variant.colors
        RoundedRectangle(cornerRadius: 8)
            .fill(colors.background.color)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(colors.text.color).frame(width: 20, height: 3)
                    Capsule().fill(colors.textMuted.color).frame(width: 13, height: 3)
                }
                .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    Circle().fill(variant.accent.primary.color)
                    Circle().fill((variant.syntax["string"] ?? colors.success).color)
                    Circle().fill(colors.warning.color)
                }
                .frame(height: 7)
                .padding(5)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.border.color, lineWidth: 1))
            .frame(width: 44, height: 32)
            .accessibilityHidden(true)
    }
}

/// A miniature Harness transcript painted in `variant`'s colors: prompt
/// bubble, reply with inline code, a code block, and status dots.
struct ThemePreviewCard: View {
    let variant: ThemeVariant

    var body: some View {
        let colors = variant.colors
        let syntax = { (key: String) in variant.syntax[key]?.color ?? variant.accent.primary.color }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 40)
                Text("Split panes evenly")
                    .font(Theme.sans(14))
                    .foregroundStyle(colors.text.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(colors.raised.color, in: RoundedRectangle(cornerRadius: 16))
            }
            (Text("Updated ").foregroundStyle(colors.text.color)
                + Text("layout.rs").foregroundStyle(variant.accent.primary.color)
                + Text(" so every pane gets an equal share.").foregroundStyle(colors.text.color))
                .font(Theme.sans(14))
            (Text("fn ").foregroundStyle(syntax("keyword"))
                + Text("split").foregroundStyle(syntax("function"))
                + Text("(n: ").foregroundStyle(colors.text.color)
                + Text("usize").foregroundStyle(syntax("type"))
                + Text(") -> ").foregroundStyle(colors.text.color)
                + Text("\"even\"").foregroundStyle(syntax("string"))
                + Text(" // ").foregroundStyle(syntax("comment"))
                + Text("1").foregroundStyle(syntax("number")))
                .font(Theme.mono(12.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.shell.color, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(colors.border.color, lineWidth: 1))
            HStack(spacing: 14) {
                status("Working", variant.accent.activity.color)
                status("Done", colors.success.color)
                status("Needs you", colors.warning.color)
                status("Failed", colors.danger.color)
            }
        }
        .padding(14)
        .background(colors.background.color, in: RoundedRectangle(cornerRadius: SheetStyle.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: SheetStyle.cardRadius)
            .strokeBorder(colors.borderStrong.color, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Text(variant.name)
                .font(Theme.sans(11, weight: .medium))
                .foregroundStyle(colors.textMuted.color)
                .padding(14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of \(variant.name)")
        .accessibilityIdentifier("theme-preview")
    }

    private func status(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(Theme.sans(11.5))
                .foregroundStyle(variant.colors.textMuted.color)
        }
    }
}
