// The two controls above the Home list: which project's sessions it shows, and
// how it groups them. They sit together on one row, as a matched pair of pills,
// so the pair reads as "what this list shows" (#419). The project choice used
// to sit alone in the nav bar as a bare "All", the grouping on a row of its own
// as a bare "Time".

import SwiftUI

enum HomeListControls {
    /// The project pill when no project is chosen. "All" alone didn't say all of what.
    static let allProjectsTitle = "All projects"

    /// The saved filter value for sessions outside any project. Space ids are
    /// never empty or start with "~", so it can't collide with one; "" stays All.
    static let projectlessFilter = "~projectless"
    static let projectlessTitle = "No project"

    /// Sessions with no project (desktop `sidebar_chats` with `Some("")`).
    static func projectless(_ chats: [Chat]) -> [Chat] {
        chats.filter { $0.spaceId == nil }
    }

    /// The project pill's text: the chosen project's name, No project, or All projects.
    static func scopeTitle(projectName: String?, projectless: Bool = false) -> String {
        if projectless { return projectlessTitle }
        guard let projectName, !projectName.isEmpty else { return allProjectsTitle }
        return projectName
    }

    /// The row shows while there is anything to scope: a session, a project to
    /// pick, or a project already picked. The last keeps the way out of a
    /// project that has no sessions yet.
    static func showsRow(hasSessions: Bool, hasProjects: Bool, projectSelected: Bool) -> Bool {
        hasSessions || hasProjects || projectSelected
    }

    /// Grouping only means something when the scope has sessions to group.
    static func showsGrouping(sessionsInScope: Int) -> Bool {
        sessionsInScope > 0
    }

    /// Top-of-screen clutter (`HomeStartHeader`, `PinnedRow`, `SplitOfferBanner`,
    /// `NowStrip`) stays off the Home list (`FrameSchedule.lean`:
    /// `clean_home_layout_has_zero_top_clutter`), so the filter pills and
    /// session rows open immediately at the top of the screen.
    static func showsTopClutter(hasSessions: Bool) -> Bool {
        false
    }

    /// Deterministic state-machine transition (`FrameSchedule.lean`: `stepUiState`).
    static func stepUiState(_ state: HomeUiState, _ event: HomeUiEvent) -> HomeUiState {
        switch event {
        case .toggleMode:
            return HomeUiState(mode: state.mode.flipped)
        case .setMode(let target):
            return HomeUiState(mode: target)
        case .resetToDefault:
            return HomeUiState.initial
        }
    }

    /// Snap to a master preset (`Zen` = all off, `Developer` = all on) and clear per-part overrides.
    static func applyPreset(_ mode: HomeUiMode) -> (modeRaw: String, overridesRaw: String) {
        (mode.rawValue, "")
    }

    /// Parse compact `"part=1,other=0"` overrides stored in `@AppStorage`.
    static func parsePartOverrides(_ raw: String) -> [HomeMovingPart: Bool] {
        var result: [HomeMovingPart: Bool] = [:]
        for entry in raw.split(separator: ",") {
            let pair = entry.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  let part = HomeMovingPart(rawValue: String(pair[0])) else { continue }
            if pair[1] == "1" { result[part] = true }
            if pair[1] == "0" { result[part] = false }
        }
        return result
    }

    static func encodePartOverrides(_ map: [HomeMovingPart: Bool]) -> String {
        HomeMovingPart.allCases.compactMap { part in
            guard let on = map[part] else { return nil }
            return "\(part.rawValue)=\(on ? "1" : "0")"
        }.joined(separator: ",")
    }

    /// Flip a single moving part independently (`FrameSchedule.lean`: `toggle_part_involutive`,
    /// `toggle_part_orthogonal`).
    static func toggleMovingPart(_ part: HomeMovingPart, baseModeRaw: String, overridesRaw: String) -> String {
        let current = HomeHierarchyProfile.resolved(baseModeRaw: baseModeRaw, overridesRaw: overridesRaw)
        var overrides = parsePartOverrides(overridesRaw)
        overrides[part] = !current.partEnabled(part)
        return encodePartOverrides(overrides)
    }

    static func setMovingPart(_ part: HomeMovingPart, on: Bool, overridesRaw: String) -> String {
        var overrides = parsePartOverrides(overridesRaw)
        overrides[part] = on
        return encodePartOverrides(overrides)
    }
}

/// UI Experience Mode State Machine (`FrameSchedule.lean`: `UiMode`, `UiState`,
/// `UiEvent`, `stepUiState`, `HierarchyProfile`).
/// - `.zen` (**Default** — "for normies"): 1 level of hierarchy (`hierarchyDepth == 1`),
///   0 auxiliary moving parts (`movingPartsCount == 0`).
/// - `.developer` (Power-user / Developer Mode): 4 levels of hierarchy
///   (`hierarchyDepth == 4`) and all 6 developer moving parts (`movingPartsCount == 6`).
enum HomeUiMode: String, CaseIterable, Identifiable, Equatable {
    case zen
    case developer

    static let storageKey = "homeUiMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zen: return "Zen"
        case .developer: return "Developer"
        }
    }

    var pillTitle: String {
        switch self {
        case .zen: return "Zen"
        case .developer: return "Dev"
        }
    }

    var symbol: String {
        switch self {
        case .zen: return "sparkles"
        case .developer: return "terminal"
        }
    }

    var flipped: HomeUiMode {
        switch self {
        case .zen: return .developer
        case .developer: return .zen
        }
    }
}

struct HomeUiState: Equatable {
    var mode: HomeUiMode = .zen
    static let initial = HomeUiState(mode: .zen)
}

enum HomeUiEvent: Equatable {
    case toggleMode
    case setMode(HomeUiMode)
    case resetToDefault
}

/// Individual hierarchy controls that can be turned on and off independently
/// (`FrameSchedule.lean`: `MovingPart`, `toggle_part_involutive`, `toggle_part_orthogonal`).
enum HomeMovingPart: String, CaseIterable, Identifiable, Equatable {
    case multiAxisFilters
    case groupedSections
    case rowTechBadges
    case gitCheckoutChrome

    static let overridesStorageKey = "homeUiPartOverrides"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .multiAxisFilters: return "Project & status filters"
        case .groupedSections: return "Grouped sections"
        case .rowTechBadges: return "Row branch & PR badges"
        case .gitCheckoutChrome: return "Git & branch in composer"
        }
    }

    var symbol: String {
        switch self {
        case .multiAxisFilters: return "line.3.horizontal.decrease.circle"
        case .groupedSections: return "rectangle.grid.1x2"
        case .rowTechBadges: return "arrow.triangle.branch"
        case .gitCheckoutChrome: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct HomeHierarchyProfile: Equatable {
    var showsOpenWorkspacesTree: Bool
    var showsMultiAxisFilters: Bool
    var showsRowTechBadges: Bool
    var showsGitCheckoutChrome: Bool
    var showsPromptRail: Bool
    var showsActionToolbar: Bool
    var flatSessionList: Bool

    static func ofMode(_ mode: HomeUiMode) -> HomeHierarchyProfile {
        switch mode {
        case .zen:
            return HomeHierarchyProfile(
                showsOpenWorkspacesTree: false,
                showsMultiAxisFilters: false,
                showsRowTechBadges: false,
                showsGitCheckoutChrome: false,
                showsPromptRail: false,
                showsActionToolbar: false,
                flatSessionList: true
            )
        case .developer:
            return HomeHierarchyProfile(
                showsOpenWorkspacesTree: true,
                showsMultiAxisFilters: true,
                showsRowTechBadges: true,
                showsGitCheckoutChrome: true,
                showsPromptRail: true,
                showsActionToolbar: true,
                flatSessionList: false
            )
        }
    }

    static func resolved(baseModeRaw: String, overridesRaw: String) -> HomeHierarchyProfile {
        let baseMode = HomeUiMode(rawValue: baseModeRaw) ?? HomeUiState.initial.mode
        var profile = ofMode(baseMode)
        let overrides = HomeListControls.parsePartOverrides(overridesRaw)
        for part in HomeMovingPart.allCases {
            if let on = overrides[part] {
                profile = profile.settingPart(part, on: on)
            }
        }
        return profile
    }

    func partEnabled(_ part: HomeMovingPart) -> Bool {
        switch part {
        case .multiAxisFilters: return showsMultiAxisFilters
        case .groupedSections: return !flatSessionList
        case .rowTechBadges: return showsRowTechBadges
        case .gitCheckoutChrome: return showsGitCheckoutChrome
        }
    }

    func settingPart(_ part: HomeMovingPart, on: Bool) -> HomeHierarchyProfile {
        var copy = self
        switch part {
        case .multiAxisFilters: copy.showsMultiAxisFilters = on
        case .groupedSections: copy.flatSessionList = !on
        case .rowTechBadges: copy.showsRowTechBadges = on
        case .gitCheckoutChrome: copy.showsGitCheckoutChrome = on
        }
        return copy
    }

    func togglingPart(_ part: HomeMovingPart) -> HomeHierarchyProfile {
        settingPart(part, on: !partEnabled(part))
    }

    var effectiveMode: HomeUiMode {
        let anyMobilePartEnabled = showsMultiAxisFilters || !flatSessionList || showsRowTechBadges || showsGitCheckoutChrome
        return anyMobilePartEnabled ? .developer : .zen
    }

    var hierarchyDepth: Int {
        1 + (showsMultiAxisFilters ? 1 : 0) + (showsOpenWorkspacesTree ? 1 : 0) + (!flatSessionList ? 1 : 0)
    }

    var movingPartsCount: Int {
        (showsOpenWorkspacesTree ? 1 : 0) +
        (showsMultiAxisFilters ? 1 : 0) +
        (showsRowTechBadges ? 1 : 0) +
        (showsGitCheckoutChrome ? 1 : 0) +
        (showsPromptRail ? 1 : 0) +
        (showsActionToolbar ? 1 : 0)
    }
}

/// Time-window filter matching the desktop sidebar's `Last activity` menu
/// (`FrameSchedule.lean`: `keepChatFixed`).
enum HomeActivityWindow: String, CaseIterable, Identifiable {
    case d1 = "1d"
    case d3 = "3d"
    case d7 = "7d"
    case d30 = "30d"
    case all = "all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .d1: return "1d"
        case .d3: return "3d"
        case .d7: return "7d"
        case .d30: return "30d"
        case .all: return "All"
        }
    }

    var cutoffMs: Int64? {
        let dayMs: Int64 = 86_400_000
        switch self {
        case .d1: return dayMs
        case .d3: return 3 * dayMs
        case .d7: return 7 * dayMs
        case .d30: return 30 * dayMs
        case .all: return nil
        }
    }

    static func keep(_ chat: Chat, indicator: ChatIndicator, window: HomeActivityWindow, nowMs: Int64) -> Bool {
        guard let cutoff = window.cutoffMs else { return true }
        if indicator == .working || indicator == .awaitingInput { return true }
        let touched = max(chat.lastMessageAt ?? 0, chat.createdAt)
        return touched >= nowMs - cutoff
    }

    static func apply(_ chats: [Chat], window: HomeActivityWindow,
                      indicator: (Chat) -> ChatIndicator, nowMs: Int64) -> [Chat] {
        guard window != .all else { return chats }
        return chats.filter { keep($0, indicator: indicator($0), window: window, nowMs: nowMs) }
    }
}

extension HomeGroupBy {
    /// The grouping pill's text. "By …" says it arranges the list, where a bare
    /// "Time" read like another filter.
    var pillTitle: String {
        switch self {
        case .status: return "By status"
        case .none: return "By time"
        case .project: return "By project"
        case .device: return "By device"
        }
    }
}

/// One of the Home list's control pills: symbol, title and a chevron in a
/// capsule. Pure native Liquid Glass (`FrameSchedule.lean`:
/// `native_glass_preserves_specular_refraction`) without an interior ink wash
/// or border overlay, matching the system's own toolbar and search bar glass.
struct HomeControlPill: View {
    let symbol: String
    let title: String
    /// Changed from its default (a project chosen, or grouped).
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.sans(Theme.previewSize, weight: active ? .semibold : .regular, relativeTo: .subheadline))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textFaint)
                .accessibilityHidden(true)
        }
        .foregroundStyle(active ? Theme.text : Theme.textMuted)
        .padding(.horizontal, 10)
        .frame(minHeight: Theme.chipHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
        // A 44pt target around the 36pt capsule.
        .frame(minHeight: Theme.hitTarget)
        .contentShape(Rectangle())
    }
}

/// 1-tap toggle capsule for Zen / Developer mode (no dropdown chevron: a single tap
/// flips immediately; long-press or the adjacent sliders menu toggles individual parts).
struct HomeModeTogglePill: View {
    let mode: HomeUiMode

    var body: some View {
        let active = mode == .developer
        HStack(spacing: 5) {
            Image(systemName: mode.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .accessibilityHidden(true)
            Text(mode.pillTitle)
                .font(Theme.sans(Theme.previewSize, weight: active ? .semibold : .medium, relativeTo: .subheadline))
                .lineLimit(1)
        }
        .foregroundStyle(active ? Theme.text : Theme.textMuted)
        .padding(.horizontal, 10)
        .frame(minHeight: Theme.chipHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
        .frame(minHeight: Theme.hitTarget)
        .contentShape(Rectangle())
    }
}

/// Shared menu items for presets (`Zen` / `Developer`) + per-part switches so any
/// surface (`HomeView`, `NewSessionView`, `SessionView`) can turn everything or
/// individual parts on and off in one place.
struct HomeExperienceMenuContent: View {
    @Binding var uiModeRaw: String
    @Binding var uiPartOverridesRaw: String

    private var profile: HomeHierarchyProfile {
        HomeHierarchyProfile.resolved(baseModeRaw: uiModeRaw, overridesRaw: uiPartOverridesRaw)
    }

    var body: some View {
        let mode = profile.effectiveMode
        Section("Experience preset") {
            Button {
                withAnimation(Motion.resort) {
                    let next = HomeListControls.applyPreset(.zen)
                    uiModeRaw = next.modeRaw
                    uiPartOverridesRaw = next.overridesRaw
                }
            } label: {
                Label("Zen (All off — simple)", systemImage: mode == .zen ? "checkmark" : "sparkles")
            }
            Button {
                withAnimation(Motion.resort) {
                    let next = HomeListControls.applyPreset(.developer)
                    uiModeRaw = next.modeRaw
                    uiPartOverridesRaw = next.overridesRaw
                }
            } label: {
                Label("Developer (All on)", systemImage: mode == .developer && uiPartOverridesRaw.isEmpty ? "checkmark" : "terminal")
            }
        }
        Section("Individual controls") {
            ForEach(HomeMovingPart.allCases) { part in
                let enabled = profile.partEnabled(part)
                Button {
                    withAnimation(Motion.resort) {
                        uiPartOverridesRaw = HomeListControls.toggleMovingPart(
                            part,
                            baseModeRaw: uiModeRaw,
                            overridesRaw: uiPartOverridesRaw
                        )
                    }
                } label: {
                    Label(part.label, systemImage: enabled ? "checkmark" : part.symbol)
                }
            }
        }
    }
}
